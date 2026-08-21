import Map "mo:map/Map";
import { thash; phash; nhash } "mo:map/Map";
import Result "mo:base/Result";
import Blob "mo:base/Blob";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Char "mo:base/Char";
import Nat32 "mo:base/Nat32";
import Nat8 "mo:base/Nat8";
import Nat64 "mo:base/Nat64";
import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import Float "mo:base/Float";
import Int "mo:base/Int";
import Nat "mo:base/Nat";
import Order "mo:base/Order";
import Time "mo:base/Time";
import Error "mo:base/Error";
import Json "mo:json";
import HttpTypes "mo:http-types";

import Mcp "mo:mcp-motoko-sdk/mcp/Mcp";
import McpTypes "mo:mcp-motoko-sdk/mcp/Types";
import AuthTypes "mo:mcp-motoko-sdk/auth/Types";
import ApiKey "mo:mcp-motoko-sdk/auth/ApiKey";
import AuthState "mo:mcp-motoko-sdk/auth/State";
import AuthCleanup "mo:mcp-motoko-sdk/auth/Cleanup";
import HttpHandler "mo:mcp-motoko-sdk/mcp/HttpHandler";
import SrvTypes "mo:mcp-motoko-sdk/server/Types";
import Cleanup "mo:mcp-motoko-sdk/mcp/Cleanup";
import State "mo:mcp-motoko-sdk/mcp/State";
import HttpAssets "mo:mcp-motoko-sdk/mcp/HttpAssets";
import Beacon "mo:mcp-motoko-sdk/mcp/Beacon";

shared ({ caller = deployer }) persistent actor class McpServer() = self {

  // --- SUBSCRIPTION DATA MODEL ---
  //
  // A subscription is a recurring obligation: a price, a cycle, and the next
  // date it renews. Everything the auditor says is derived from those three
  // plus history — what the price used to be, when you last used it.
  //
  // Two kinds live in the same registry:
  //
  //   off-chain — Netflix, a gym, a SaaS seat. The canister records and
  //   reasons about it, and CANNOT cancel it. Nothing on chain can: there is
  //   no credential and no browser here. Cancelling is handed back as a
  //   checklist for a human or a browser agent to execute.
  //
  //   on-chain  — anything an agent pays through an ICRC-2 allowance. The
  //   canister reads the live allowance straight off the ledger, so it can
  //   prove whether a standing permission is still open. It still cannot
  //   revoke it: only the account owner may call icrc2_approve on their own
  //   account. Revocation is returned as the exact call to make.
  //
  // Dates are days since the Unix epoch in UTC. Renewal dates are dates, not
  // instants — a subscription renews on a day, and the hour it lands is the
  // vendor's business, not something worth pretending to know.

  type Cycle = { #weekly; #monthly; #quarterly; #yearly; #days : Nat };

  type Status = { #active; #trial; #paused; #cancelled };

  type OnChain = {
    ledger : Text; // ledger canister id
    spender : Principal; // who is allowed to pull
    account : Principal; // whose account the allowance was granted from
    lastAllowance : ?Nat; // last observed allowance, minor units
    lastCheckedAt : ?Int; // ns
  };

  type PricePoint = { day : Int; cents : Nat };

  type Event = { at : Int; event : Text };

  type Sub = {
    id : Nat;
    owner : Principal;
    name : Text;
    vendor : ?Text;
    category : Text;
    cents : Nat; // price per cycle, minor units of `currency`
    currency : Text;
    cycle : Cycle;
    nextRenewal : Int; // days since epoch
    status : Status;
    trialEnds : ?Int; // days since epoch
    lastUsed : ?Int; // days since epoch
    startedOn : Int; // days since epoch
    cancelledOn : ?Int;
    cancelReason : ?Text;
    notes : ?Text;
    onchain : ?OnChain;
    priceHistory : [PricePoint];
    events : [Event];
    createdAt : Int;
    updatedAt : Int;
  };

  var nextSubId : Nat = 1;
  let subsById : Map.Map<Nat, Sub> = Map.new();
  let subIdsByOwner : Map.Map<Principal, [Nat]> = Map.new();

  // Ledger metadata (symbol, decimals) is fetched once per ledger and cached;
  // it only changes if a ledger is replaced, which is not a thing that happens
  // quietly.
  transient let ledgerMeta : Map.Map<Text, (Text, Nat)> = Map.new();

  // Thresholds the audit reasons with. Deliberately boring numbers, stated
  // out loud in the tool description so nobody has to guess what "unused" means.
  transient let unusedAfterDays : Int = 60;
  transient let trialWarningDays : Int = 14;
  transient let defaultHorizonDays : Int = 30;

  // --- MCP SERVER PLUMBING ---

  var stable_http_assets : HttpAssets.StableEntries = [];
  transient let http_assets = HttpAssets.init(stable_http_assets);

  let appContext : McpTypes.AppContext = State.init([]);
  let authContext : AuthTypes.AuthContext = AuthState.initApiKey(deployer);

  Cleanup.startCleanupTimer<system>(appContext);
  AuthCleanup.startCleanupTimer<system>(authContext);

  // Prometheus usage beacon — reports anonymized usage to the tracker canister.
  transient let beaconContext : Beacon.BeaconContext = Beacon.init(
    Principal.fromText("m63pw-fqaaa-aaaai-q33pa-cai"),
    ?(15 * 60),
  );
  Beacon.startTimer<system>(beaconContext);

  // --- ICRC-2 LEDGER READS ---
  //
  // Read-only. This canister never approves, transfers, or holds anything —
  // it asks a ledger what allowance is standing and reports the answer.

  transient let defaultLedger : Text = "xevnm-gaaaa-aaaar-qafnq-cai"; // ckUSDC

  type Account = { owner : Principal; subaccount : ?Blob };
  type AllowanceArgs = { account : Account; spender : Account };
  type Allowance = { allowance : Nat; expires_at : ?Nat64 };

  func ledgerOf(id : Text) : actor {
    icrc2_allowance : (AllowanceArgs) -> async Allowance;
    icrc1_symbol : () -> async Text;
    icrc1_decimals : () -> async Nat8;
  } {
    actor (id);
  };

  // --- CALENDAR MATH ---
  //
  // Days are days-since-epoch; the civil <-> days conversion is Howard
  // Hinnant's algorithm, which relies on division truncating toward zero
  // exactly as Motoko's Int division does.

  transient let nanosPerDay : Int = 86_400_000_000_000;

  func floorDiv(a : Int, b : Int) : Int {
    let q = a / b;
    if (a % b != 0 and ((a < 0) != (b < 0))) q - 1 else q;
  };

  func floorMod(a : Int, b : Int) : Int { a - floorDiv(a, b) * b };

  func daysFromCivil(y0 : Int, m : Int, d : Int) : Int {
    let y = if (m <= 2) y0 - 1 else y0;
    let era = (if (y >= 0) y else y - 399) / 400;
    let yoe = y - era * 400; // [0, 399]
    let mp = floorMod(m + 9, 12); // March = 0
    let doy = (153 * mp + 2) / 5 + d - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    era * 146097 + doe - 719468;
  };

  func civilFromDays(z0 : Int) : (Int, Int, Int) {
    let z = z0 + 719468;
    let era = (if (z >= 0) z else z - 146096) / 146097;
    let doe = z - era * 146097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    (if (m <= 2) y + 1 else y, m, d);
  };

  func today() : Int { floorDiv(Time.now(), nanosPerDay) };

  func daysInMonth(y : Int, m : Int) : Int {
    let (ny, nm) = if (m == 12) (y + 1, 1) else (y, m + 1);
    daysFromCivil(ny, nm, 1) - daysFromCivil(y, m, 1);
  };

  /// Add calendar months, clamping the day of month (Jan 31 + 1 month = Feb 28).
  func addMonths(day : Int, n : Int) : Int {
    let (y, m, d) = civilFromDays(day);
    let total = y * 12 + (m - 1) + n;
    let ny = floorDiv(total, 12);
    let nm = floorMod(total, 12) + 1;
    let dim = daysInMonth(ny, nm);
    daysFromCivil(ny, nm, if (d > dim) dim else d);
  };

  func addCycle(day : Int, c : Cycle) : Int {
    switch (c) {
      case (#weekly) day + 7;
      case (#monthly) addMonths(day, 1);
      case (#quarterly) addMonths(day, 3);
      case (#yearly) addMonths(day, 12);
      case (#days(n)) day + n;
    };
  };

  func pad2(n : Int) : Text {
    let a = Int.abs(n);
    if (a < 10) "0" # Nat.toText(a) else Nat.toText(a);
  };

  func fmtDate(days : Int) : Text {
    let (y, m, d) = civilFromDays(days);
    Int.toText(y) # "-" # pad2(m) # "-" # pad2(d);
  };

  func cycleText(c : Cycle) : Text {
    switch (c) {
      case (#weekly) "weekly";
      case (#monthly) "monthly";
      case (#quarterly) "quarterly";
      case (#yearly) "yearly";
      case (#days(n)) "every " # Nat.toText(n) # " days";
    };
  };

  func statusText(s : Status) : Text {
    switch (s) {
      case (#active) "active";
      case (#trial) "trial";
      case (#paused) "paused";
      case (#cancelled) "cancelled";
    };
  };

  /// Periods per year. 365.25 keeps leap years from quietly shaving a day off
  /// every annualized figure.
  func periodsPerYear(c : Cycle) : Float {
    switch (c) {
      case (#weekly) 365.25 / 7.0;
      case (#monthly) 12.0;
      case (#quarterly) 4.0;
      case (#yearly) 1.0;
      case (#days(n)) 365.25 / Float.fromInt(n);
    };
  };

  func roundCents(f : Float) : Nat {
    if (f <= 0.0) return 0;
    Int.abs(Float.toInt(f + 0.5));
  };

  func annualCents(s : Sub) : Nat {
    roundCents(Float.fromInt(s.cents) * periodsPerYear(s.cycle));
  };

  func monthlyCents(s : Sub) : Nat {
    roundCents(Float.fromInt(s.cents) * periodsPerYear(s.cycle) / 12.0);
  };

  func fmtMoney(cents : Nat, currency : Text) : Text {
    let body = Nat.toText(cents / 100) # "." # pad2(cents % 100);
    if (currency == "USD") "$" # body else body # " " # currency;
  };

  /// Advance a renewal date past today, reporting how many cycles it skipped.
  /// A registry nobody has touched in three months should still name the right
  /// next date rather than a stale one in the past.
  func rollForward(from : Int, c : Cycle, todayDay : Int) : (Int, Nat) {
    var d = from;
    var skipped : Nat = 0;
    // A cycle always advances by at least a day, so this terminates; the cap is
    // belt-and-braces against a corrupted record.
    while (d < todayDay and skipped < 500) {
      d := addCycle(d, c);
      skipped += 1;
    };
    (d, skipped);
  };

  // --- TEXT PARSING ---

  func digitsToNat(t : Text) : ?Nat {
    if (t.size() == 0) return null;
    var acc : Nat = 0;
    for (c in t.chars()) {
      if (not Char.isDigit(c)) return null;
      acc := acc * 10 + Nat32.toNat(Char.toNat32(c) - 48);
    };
    ?acc;
  };

  func lower(t : Text) : Text {
    Text.map(
      t,
      func(c : Char) : Char {
        let n = Char.toNat32(c);
        if (n >= 65 and n <= 90) Char.fromNat32(n + 32) else c;
      },
    );
  };

  func splitParts(t : Text, sep : Char) : [Text] {
    Buffer.toArray(
      do {
        let out = Buffer.Buffer<Text>(4);
        for (piece in Text.split(t, #char sep)) out.add(piece);
        out;
      }
    );
  };

  /// "YYYY-MM-DD" -> days since epoch.
  func parseDate(t : Text) : ?Int {
    let parts = splitParts(Text.trim(t, #char ' '), '-');
    if (parts.size() != 3) return null;
    let ?y = digitsToNat(parts[0]) else return null;
    let ?m = digitsToNat(parts[1]) else return null;
    let ?d = digitsToNat(parts[2]) else return null;
    if (y < 2020 or y > 2100 or m < 1 or m > 12 or d < 1 or d > 31) return null;
    let days = daysFromCivil(y, m, d);
    // Reject impossible dates (Feb 30) by round-tripping.
    let (ry, rm, rd) = civilFromDays(days);
    if (ry != y or rm != m or rd != d) return null;
    ?days;
  };

  /// A date argument: "today", "tomorrow", "+30", "-7", or "YYYY-MM-DD".
  func parseDayArg(t : Text) : ?Int {
    let v = lower(Text.trim(t, #char ' '));
    if (v == "today" or v == "now") return ?today();
    if (v == "tomorrow") return ?(today() + 1);
    if (v == "yesterday") return ?(today() - 1);
    switch (parseDate(v)) {
      case (?d) ?d;
      case (null) {
        if (Text.startsWith(v, #char '+')) {
          switch (digitsToNat(Text.trimStart(v, #char '+'))) {
            case (?n) ?(today() + n);
            case (null) null;
          };
        } else if (Text.startsWith(v, #char '-')) {
          switch (digitsToNat(Text.trimStart(v, #char '-'))) {
            case (?n) ?(today() - n);
            case (null) null;
          };
        } else null;
      };
    };
  };

  /// "monthly", "annual", "every 30 days", "30 days", "quarterly", "weekly".
  func parseCycle(t : Text) : ?Cycle {
    let v = lower(Text.trim(t, #char ' '));
    if (v == "weekly" or v == "week" or v == "wk") return ?#weekly;
    if (v == "monthly" or v == "month" or v == "mo") return ?#monthly;
    if (v == "quarterly" or v == "quarter") return ?#quarterly;
    if (v == "yearly" or v == "annual" or v == "annually" or v == "year") return ?#yearly;
    // "every N days" / "N days" / "N"
    let cleaned = Text.trim(Text.replace(Text.replace(v, #text "every ", ""), #text "days", ""), #char ' ');
    let trimmed = Text.trim(Text.trim(cleaned, #char ' '), #char 'd');
    switch (digitsToNat(Text.trim(trimmed, #char ' '))) {
      case (?n) { if (n >= 1 and n <= 3650) ?#days(n) else null };
      case (null) null;
    };
  };

  func parseStatus(t : Text) : ?Status {
    switch (lower(Text.trim(t, #char ' '))) {
      case ("active") ?#active;
      case ("trial") ?#trial;
      case ("paused") ?#paused;
      case ("cancelled") ?#cancelled;
      case ("canceled") ?#cancelled;
      case (_) null;
    };
  };

  // Principal.fromText traps on a bad checksum, which surfaces as a canister
  // error rather than a tool error — so screen the shape first.
  func parsePrincipal(t : Text) : ?Principal {
    let trimmed = Text.trim(t, #char ' ');
    let n = trimmed.size();
    if (n < 5 or n > 63) return null;
    for (c in trimmed.chars()) {
      let ok = (Char.isLowercase(c) and Char.isAlphabetic(c)) or Char.isDigit(c) or c == '-';
      if (not ok) return null;
    };
    let p = Principal.fromText(trimmed);
    if (Principal.isAnonymous(p)) return null;
    ?p;
  };

  // --- ARG HELPERS ---

  func optText(args : McpTypes.JsonValue, field : Text) : ?Text {
    switch (Result.toOption(Json.getAsText(args, field))) {
      case (?t) { let v = Text.trim(t, #char ' '); if (v == "") null else ?v };
      case (null) null;
    };
  };

  // Plain decimal only: optional leading '-', digits, at most one '.'.
  func floatFromText(t : Text) : ?Float {
    var whole : Float = 0.0;
    var frac : Float = 0.0;
    var scale : Float = 1.0;
    var seenDot = false;
    var seenDigit = false;
    var negative = false;
    var first = true;
    for (c in t.chars()) {
      if (first and c == '-') {
        negative := true;
      } else if (c == '.') {
        if (seenDot) return null;
        seenDot := true;
      } else if (Char.isDigit(c)) {
        seenDigit := true;
        let d = Float.fromInt(Nat32.toNat(Char.toNat32(c) - 48));
        if (seenDot) { scale *= 10.0; frac += d / scale } else {
          whole := whole * 10.0 + d;
        };
      } else if (c == ',' or c == '$') {
        // Agents pass "$12.99" and "1,200" more often than you'd like.
      } else return null;
      first := false;
    };
    if (not seenDigit) return null;
    let v = whole + frac;
    ?(if (negative) -v else v);
  };

  // Accepts either a JSON number or a numeric string — agents often stringify.
  func optFloat(args : McpTypes.JsonValue, field : Text) : ?Float {
    switch (Result.toOption(Json.getAsFloat(args, field))) {
      case (?f) ?f;
      case (null) {
        switch (Result.toOption(Json.getAsText(args, field))) {
          case (?t) floatFromText(Text.trim(t, #char ' '));
          case (null) null;
        };
      };
    };
  };

  func optNat(args : McpTypes.JsonValue, field : Text) : ?Nat {
    switch (optFloat(args, field)) {
      case (?f) { if (f < 0.0) null else ?Int.abs(Float.toInt(f + 0.5)) };
      case (null) null;
    };
  };

  /// A price in major units (12.99) -> minor units (1299).
  func optCents(args : McpTypes.JsonValue, field : Text) : ?Nat {
    switch (optFloat(args, field)) {
      case (?f) { if (f < 0.0) null else ?roundCents(f * 100.0) };
      case (null) null;
    };
  };

  func errorResult(msg : Text) : McpTypes.CallToolResult {
    { content = [#text({ text = msg })]; isError = true; structuredContent = null };
  };

  func okResult(payload : Json.Json) : McpTypes.CallToolResult {
    {
      content = [#text({ text = Json.stringify(payload, null) })];
      isError = false;
      structuredContent = ?payload;
    };
  };

  func optJsonText(t : ?Text) : Json.Json {
    switch (t) { case (?v) Json.str(v); case (null) Json.nullable() };
  };

  func optJsonDate(d : ?Int) : Json.Json {
    switch (d) { case (?v) Json.str(fmtDate(v)); case (null) Json.nullable() };
  };

  // --- STORAGE HELPERS ---

  func ownerIds(p : Principal) : [Nat] {
    switch (Map.get(subIdsByOwner, phash, p)) { case (?ids) ids; case (null) [] };
  };

  func ownerSubs(p : Principal) : [Sub] {
    let out = Buffer.Buffer<Sub>(8);
    for (id in ownerIds(p).vals()) {
      switch (Map.get(subsById, nhash, id)) { case (?s) out.add(s); case (null) {} };
    };
    Buffer.toArray(out);
  };

  func putSub(s : Sub) {
    Map.set(subsById, nhash, s.id, s);
  };

  func withEvent(s : Sub, event : Text, now : Int) : Sub {
    { s with events = Array.append(s.events, [{ at = now; event = event }]); updatedAt = now };
  };

  func ownedSub(p : Principal, id : Nat) : ?Sub {
    switch (Map.get(subsById, nhash, id)) {
      case (?s) { if (s.owner == p) ?s else null };
      case (null) null;
    };
  };

  func isLive(s : Sub) : Bool {
    s.status == #active or s.status == #trial;
  };

  func firstPrice(s : Sub) : Nat {
    if (s.priceHistory.size() == 0) s.cents else s.priceHistory[0].cents;
  };

  // --- JSON VIEWS ---

  func onchainToJson(o : OnChain) : Json.Json {
    Json.obj([
      ("ledger", Json.str(o.ledger)),
      ("spender", Json.str(Principal.toText(o.spender))),
      ("account", Json.str(Principal.toText(o.account))),
      ("last_seen_allowance_raw", switch (o.lastAllowance) { case (?a) Json.int(a); case (null) Json.nullable() }),
      ("last_checked_at_ns", switch (o.lastCheckedAt) { case (?t) Json.int(t); case (null) Json.nullable() }),
    ]);
  };

  func subToJson(s : Sub, todayDay : Int, full : Bool) : Json.Json {
    let (nextDay, _) = rollForward(s.nextRenewal, s.cycle, todayDay);
    let live = isLive(s);
    let base = [
      ("id", Json.int(s.id)),
      ("name", Json.str(s.name)),
      ("vendor", optJsonText(s.vendor)),
      ("category", Json.str(s.category)),
      ("status", Json.str(statusText(s.status))),
      ("kind", Json.str(switch (s.onchain) { case (?_) "on-chain"; case (null) "off-chain" })),
      ("price", Json.str(fmtMoney(s.cents, s.currency))),
      ("price_minor_units", Json.int(s.cents)),
      ("currency", Json.str(s.currency)),
      ("cycle", Json.str(cycleText(s.cycle))),
      ("monthly_equivalent", Json.str(fmtMoney(monthlyCents(s), s.currency))),
      ("annual_cost", Json.str(fmtMoney(annualCents(s), s.currency))),
      ("annual_cost_minor_units", Json.int(annualCents(s))),
      ("next_renewal", if (live) Json.str(fmtDate(nextDay)) else Json.nullable()),
      ("days_until_renewal", if (live) Json.int(nextDay - todayDay) else Json.nullable()),
      ("trial_ends", optJsonDate(s.trialEnds)),
      ("last_used", optJsonDate(s.lastUsed)),
      ("started_on", Json.str(fmtDate(s.startedOn))),
      ("cancelled_on", optJsonDate(s.cancelledOn)),
      ("cancel_reason", optJsonText(s.cancelReason)),
      ("on_chain", switch (s.onchain) { case (?o) onchainToJson(o); case (null) Json.nullable() }),
    ];
    if (not full) return Json.obj(base);
    Json.obj(
      Array.append(
        base,
        [
          ("notes", optJsonText(s.notes)),
          (
            "price_history",
            Json.arr(
              Array.map<PricePoint, Json.Json>(
                s.priceHistory,
                func(p) { Json.obj([("on", Json.str(fmtDate(p.day))), ("price", Json.str(fmtMoney(p.cents, s.currency)))]) },
              )
            ),
          ),
          (
            "events",
            Json.arr(
              Array.map<Event, Json.Json>(
                s.events,
                func(e) { Json.obj([("at_ns", Json.int(e.at)), ("event", Json.str(e.event))]) },
              )
            ),
          ),
        ],
      )
    );
  };

  /// The one thing this canister will never do, said the same way every time.
  func cancelInstructions(s : Sub) : Json.Json {
    switch (s.onchain) {
      case (?o) {
        Json.obj([
          ("cancellable_here", Json.bool(false)),
          ("how", Json.str("Revoke the allowance from the account that granted it. On ledger " # o.ledger # ", call icrc2_approve with spender = " # Principal.toText(o.spender) # " and amount = 0, signed by " # Principal.toText(o.account) # ". Only that principal can do it — this canister has no authority over your account and never will.")),
          ("dfx", Json.str("dfx canister --network ic call " # o.ledger # " icrc2_approve '(record { spender = record { owner = principal \"" # Principal.toText(o.spender) # "\" }; amount = 0 })'")),
          ("then", Json.str("Run check_allowances afterwards — a revocation that worked reads back as 0 from the ledger.")),
        ]);
      };
      case (null) {
        Json.obj([
          ("cancellable_here", Json.bool(false)),
          ("how", Json.str("Cancel with the vendor directly — this is an off-chain subscription and no canister can reach it. Cancel before " # fmtDate(rollForward(s.nextRenewal, s.cycle, today()).0) # " to avoid the next charge, then mark it cancelled here so the audit stops counting it.")),
          ("note", Json.str("Recording it here is bookkeeping, not cancellation. Nothing in this server has touched the vendor.")),
        ]);
      };
    };
  };

  // --- TOOL SCHEMAS ---

  func schemaProp(name : Text, jsonType : Text, description : Text) : (Text, Json.Json) {
    (name, Json.obj([("type", Json.str(jsonType)), ("description", Json.str(description))]));
  };

  func objSchema(props : [(Text, Json.Json)], required : [Text]) : Json.Json {
    Json.obj([
      ("type", Json.str("object")),
      ("properties", Json.obj(props)),
      ("required", Json.arr(Array.map<Text, Json.Json>(required, Json.str))),
    ]);
  };

  transient let subResultSchema : Json.Json = objSchema(
    [
      schemaProp("message", "string", "Confirmation message."),
      ("subscription", Json.obj([("type", Json.str("object"))])),
    ],
    ["message"],
  );

  transient let tools : [McpTypes.Tool] = [
    {
      name = "add_subscription";
      title = ?"Add Subscription";
      description = ?"Record a recurring charge: what it is, what it costs, how often, and when it next renews. Pass a spender principal to register it as an on-chain subscription paid through an ICRC-2 allowance, which can then be read back off the ledger.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("name", "string", "What it is, e.g. 'Netflix' or 'Claude Pro'."),
          schemaProp("amount", "number", "Price per cycle in major units, e.g. 12.99."),
          schemaProp("cycle", "string", "How often it charges: weekly, monthly, quarterly, yearly, or 'every N days'."),
          schemaProp("next_renewal", "string", "Next charge date: 'YYYY-MM-DD', 'today', or '+30'. Defaults to one cycle from today."),
          schemaProp("category", "string", "Optional grouping, e.g. 'streaming', 'software', 'fitness'. Used to spot overlap."),
          schemaProp("currency", "string", "Optional currency code, default USD."),
          schemaProp("status", "string", "active (default), trial, paused, or cancelled."),
          schemaProp("trial_ends", "string", "If this is a trial, the date it converts to paid: 'YYYY-MM-DD' or '+14'."),
          schemaProp("started_on", "string", "Optional date you first subscribed, for lifetime-cost math."),
          schemaProp("vendor", "string", "Optional vendor name if different from the subscription name."),
          schemaProp("notes", "string", "Optional free-form notes. Don't put card numbers here — this is a public chain."),
          schemaProp("spender", "string", "On-chain only: the principal allowed to pull from your account under an ICRC-2 allowance."),
          schemaProp("ledger", "string", "On-chain only: ledger canister id. Defaults to the ckUSDC ledger."),
          schemaProp("account", "string", "On-chain only: the principal that granted the allowance. Defaults to your calling principal — set it explicitly if your wallet is a different identity than this session."),
        ],
        ["name", "amount", "cycle"],
      );
      outputSchema = ?subResultSchema;
    },
    {
      name = "update_subscription";
      title = ?"Update Subscription";
      description = ?"Change a subscription's price, cycle, renewal date, status, category, or notes. A price change is recorded in the price history, which is what the audit's price-increase detection reads.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("id", "number", "The subscription id."),
          schemaProp("amount", "number", "New price per cycle in major units."),
          schemaProp("cycle", "string", "New cycle: weekly, monthly, quarterly, yearly, or 'every N days'."),
          schemaProp("next_renewal", "string", "New next-charge date."),
          schemaProp("status", "string", "active, trial, paused, or cancelled."),
          schemaProp("category", "string", "New category."),
          schemaProp("trial_ends", "string", "New trial conversion date."),
          schemaProp("vendor", "string", "New vendor name."),
          schemaProp("notes", "string", "Replace the notes."),
        ],
        ["id"],
      );
      outputSchema = ?subResultSchema;
    },
    {
      name = "list_subscriptions";
      title = ?"List Subscriptions";
      description = ?"List your subscriptions with monthly and annual equivalents, newest renewals first by default. Filter by status, category, or kind (on-chain / off-chain).";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("status", "string", "Filter: active, trial, paused, cancelled, or 'live' for active+trial (default)."),
          schemaProp("category", "string", "Filter to one category."),
          schemaProp("kind", "string", "Filter: on-chain or off-chain."),
          schemaProp("sort", "string", "renewal (default) or cost."),
          schemaProp("limit", "number", "Max rows, default 100."),
        ],
        [],
      );
      outputSchema = ?objSchema(
        [
          schemaProp("count", "number", "Rows returned."),
          ("subscriptions", Json.obj([("type", Json.str("array"))])),
        ],
        ["count", "subscriptions"],
      );
    },
    {
      name = "get_subscription";
      title = ?"Get Subscription";
      description = ?"Full detail on one subscription: price history, event log, on-chain allowance link, and how to cancel it.";
      payment = null;
      inputSchema = objSchema([schemaProp("id", "number", "The subscription id.")], ["id"]);
      outputSchema = ?objSchema([("subscription", Json.obj([("type", Json.str("object"))]))], ["subscription"]);
    },
    {
      name = "mark_used";
      title = ?"Mark Used";
      description = ?"Record that you actually used a subscription today (or on a given date). This is what makes 'you haven't touched this in two months' a fact rather than a guess.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("id", "number", "The subscription id."),
          schemaProp("on", "string", "Date used: 'today' (default), 'yesterday', '-3', or 'YYYY-MM-DD'."),
        ],
        ["id"],
      );
      outputSchema = ?subResultSchema;
    },
    {
      name = "cancel_subscription";
      title = ?"Cancel Subscription";
      description = ?"Mark a subscription cancelled and record what it saves per year. This does NOT cancel anything with the vendor and cannot revoke an allowance — it returns the exact steps to do that yourself, and records your decision.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("id", "number", "The subscription id."),
          schemaProp("reason", "string", "Why you're cancelling. Worth recording — future you asks."),
        ],
        ["id"],
      );
      outputSchema = ?subResultSchema;
    },
    {
      name = "audit";
      title = ?"Audit Subscriptions";
      description = ?"The full sweep: total monthly and annual spend, spend by category, renewals in the next N days, trials about to convert, prices that went up since you signed up, subscriptions unused for 60+ days, categories with overlapping subscriptions, and standing allowances on things you already cancelled — each with what dropping it would save per year.";
      payment = null;
      inputSchema = objSchema(
        [schemaProp("days", "number", "How far ahead to look for renewals, default 30.")],
        [],
      );
      outputSchema = ?objSchema([("audit", Json.obj([("type", Json.str("object"))]))], ["audit"]);
    },
    {
      name = "check_allowances";
      title = ?"Check Allowances";
      description = ?"Read the live ICRC-2 allowance for your on-chain subscriptions straight off the ledger: what each spender may still pull from you, whether it changed since last check, and whether anything you cancelled still has a standing permission. Read-only — this canister cannot approve or revoke on your behalf.";
      payment = null;
      inputSchema = objSchema(
        [schemaProp("id", "number", "Optional: check one subscription instead of all on-chain ones.")],
        [],
      );
      outputSchema = ?objSchema(
        [
          schemaProp("checked", "number", "How many allowances were read."),
          ("allowances", Json.obj([("type", Json.str("array"))])),
        ],
        ["checked", "allowances"],
      );
    },
    {
      name = "delete_subscription";
      title = ?"Delete Subscription";
      description = ?"Permanently remove a subscription record and its history. For mistakes — to stop counting something you actually cancelled, use cancel_subscription instead, which keeps the record.";
      payment = null;
      inputSchema = objSchema([schemaProp("id", "number", "The subscription id.")], ["id"]);
      outputSchema = ?objSchema([schemaProp("message", "string", "Confirmation message.")], ["message"]);
    },
  ];

  // --- TOOL IMPLEMENTATIONS ---

  type ToolCb = (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> ();

  func callerPrincipal(auth : ?AuthTypes.AuthInfo) : ?Principal {
    switch (auth) {
      case (?a) ?a.principal;
      case (null) null;
    };
  };

  func requireAuth(auth : ?AuthTypes.AuthInfo, cb : ToolCb) : ?Principal {
    switch (callerPrincipal(auth)) {
      case (?p) ?p;
      case (null) {
        cb(#ok(errorResult("Authentication required: call this tool with a valid x-api-key.")));
        null;
      };
    };
  };

  func subResponse(s : Sub, message : Text, todayDay : Int) : Json.Json {
    Json.obj([
      ("message", Json.str(message)),
      ("subscription", subToJson(s, todayDay, false)),
    ]);
  };

  func addSubscriptionTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?name = optText(args, "name") else return cb(#ok(errorResult("Missing 'name'.")));
    let ?cents = optCents(args, "amount") else return cb(#ok(errorResult("Missing or non-numeric 'amount'. Give the price per cycle in major units, e.g. 12.99.")));
    let ?cycleT = optText(args, "cycle") else return cb(#ok(errorResult("Missing 'cycle'. Use weekly, monthly, quarterly, yearly, or 'every N days'.")));
    let ?cycle = parseCycle(cycleT) else return cb(#ok(errorResult("'" # cycleT # "' is not a cycle. Use weekly, monthly, quarterly, yearly, or 'every N days'.")));

    let now = Time.now();
    let todayDay = today();

    let nextRenewal = switch (optText(args, "next_renewal")) {
      case (?t) {
        let ?d = parseDayArg(t) else return cb(#ok(errorResult("'" # t # "' is not a date. Use 'YYYY-MM-DD', 'today', or '+30'.")));
        d;
      };
      case (null) addCycle(todayDay, cycle);
    };

    let status = switch (optText(args, "status")) {
      case (?t) {
        let ?s = parseStatus(t) else return cb(#ok(errorResult("'" # t # "' is not a status. Use active, trial, paused, or cancelled.")));
        s;
      };
      case (null) #active;
    };

    let trialEnds = switch (optText(args, "trial_ends")) {
      case (?t) {
        let ?d = parseDayArg(t) else return cb(#ok(errorResult("'" # t # "' is not a date for 'trial_ends'.")));
        ?d;
      };
      case (null) null;
    };

    let startedOn = switch (optText(args, "started_on")) {
      case (?t) {
        let ?d = parseDayArg(t) else return cb(#ok(errorResult("'" # t # "' is not a date for 'started_on'.")));
        d;
      };
      case (null) todayDay;
    };

    let onchain : ?OnChain = switch (optText(args, "spender")) {
      case (?spenderT) {
        let ?spender = parsePrincipal(spenderT) else return cb(#ok(errorResult("'spender' is not a valid principal.")));
        let ledgerId = switch (optText(args, "ledger")) {
          case (?l) {
            let ?_ = parsePrincipal(l) else return cb(#ok(errorResult("'ledger' is not a valid canister id.")));
            l;
          };
          case (null) defaultLedger;
        };
        let account = switch (optText(args, "account")) {
          case (?a) {
            let ?parsed = parsePrincipal(a) else return cb(#ok(errorResult("'account' is not a valid principal.")));
            parsed;
          };
          case (null) p;
        };
        ?{
          ledger = ledgerId;
          spender = spender;
          account = account;
          lastAllowance = null;
          lastCheckedAt = null;
        };
      };
      case (null) null;
    };

    let id = nextSubId;
    nextSubId += 1;
    let s : Sub = {
      id = id;
      owner = p;
      name = name;
      vendor = optText(args, "vendor");
      category = switch (optText(args, "category")) { case (?c) lower(c); case (null) "uncategorized" };
      cents = cents;
      currency = switch (optText(args, "currency")) { case (?c) c; case (null) "USD" };
      cycle = cycle;
      nextRenewal = nextRenewal;
      status = status;
      trialEnds = trialEnds;
      lastUsed = null;
      startedOn = startedOn;
      cancelledOn = null;
      cancelReason = null;
      notes = optText(args, "notes");
      onchain = onchain;
      priceHistory = [{ day = todayDay; cents = cents }];
      events = [{ at = now; event = "Added at " # fmtMoney(cents, switch (optText(args, "currency")) { case (?c) c; case (null) "USD" }) # " " # cycleText(cycle) # "." }];
      createdAt = now;
      updatedAt = now;
    };
    putSub(s);
    Map.set(subIdsByOwner, phash, p, Array.append(ownerIds(p), [id]));

    let annual = fmtMoney(annualCents(s), s.currency);
    cb(#ok(okResult(subResponse(s, "Tracking '" # name # "' at " # fmtMoney(cents, s.currency) # " " # cycleText(cycle) # " — " # annual # " a year. Next charge " # fmtDate(nextRenewal) # ".", todayDay))));
  };

  func updateSubscriptionTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?id = optNat(args, "id") else return cb(#ok(errorResult("Missing or non-numeric 'id'.")));
    let ?s = ownedSub(p, id) else return cb(#ok(errorResult("No subscription " # Nat.toText(id) # " in your registry.")));

    let now = Time.now();
    let todayDay = today();
    var updated = s;
    let changes = Buffer.Buffer<Text>(4);

    switch (optCents(args, "amount")) {
      case (?cents) {
        if (cents != updated.cents) {
          let direction = if (cents > updated.cents) "rose" else "fell";
          changes.add("Price " # direction # " from " # fmtMoney(updated.cents, updated.currency) # " to " # fmtMoney(cents, updated.currency));
          updated := {
            updated with
            cents = cents;
            priceHistory = Array.append(updated.priceHistory, [{ day = todayDay; cents = cents }]);
          };
        };
      };
      case (null) {};
    };

    switch (optText(args, "cycle")) {
      case (?t) {
        let ?c = parseCycle(t) else return cb(#ok(errorResult("'" # t # "' is not a cycle.")));
        if (c != updated.cycle) {
          changes.add("Cycle changed from " # cycleText(updated.cycle) # " to " # cycleText(c));
          updated := { updated with cycle = c };
        };
      };
      case (null) {};
    };

    switch (optText(args, "next_renewal")) {
      case (?t) {
        let ?d = parseDayArg(t) else return cb(#ok(errorResult("'" # t # "' is not a date.")));
        changes.add("Next renewal set to " # fmtDate(d));
        updated := { updated with nextRenewal = d };
      };
      case (null) {};
    };

    switch (optText(args, "status")) {
      case (?t) {
        let ?st = parseStatus(t) else return cb(#ok(errorResult("'" # t # "' is not a status.")));
        if (st != updated.status) {
          changes.add("Status " # statusText(updated.status) # " -> " # statusText(st));
          updated := {
            updated with
            status = st;
            cancelledOn = if (st == #cancelled) ?todayDay else null;
          };
        };
      };
      case (null) {};
    };

    switch (optText(args, "category")) {
      case (?c) { changes.add("Category set to " # lower(c)); updated := { updated with category = lower(c) } };
      case (null) {};
    };

    switch (optText(args, "trial_ends")) {
      case (?t) {
        let ?d = parseDayArg(t) else return cb(#ok(errorResult("'" # t # "' is not a date.")));
        changes.add("Trial ends " # fmtDate(d));
        updated := { updated with trialEnds = ?d };
      };
      case (null) {};
    };

    switch (optText(args, "vendor")) {
      case (?v) { updated := { updated with vendor = ?v }; changes.add("Vendor set to " # v) };
      case (null) {};
    };

    switch (optText(args, "notes")) {
      case (?n) { updated := { updated with notes = ?n }; changes.add("Notes updated") };
      case (null) {};
    };

    if (changes.size() == 0) {
      return cb(#ok(errorResult("Nothing to change. Pass at least one of: amount, cycle, next_renewal, status, category, trial_ends, vendor, notes.")));
    };

    let summary = Text.join("; ", changes.vals());
    updated := withEvent(updated, summary # ".", now);
    putSub(updated);
    cb(#ok(okResult(subResponse(updated, summary # ". Now " # fmtMoney(annualCents(updated), updated.currency) # " a year.", todayDay))));
  };

  func listSubscriptionsTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let todayDay = today();
    let all = ownerSubs(p);

    let statusFilter = switch (optText(args, "status")) { case (?t) lower(t); case (null) "live" };
    let categoryFilter = switch (optText(args, "category")) { case (?c) ?lower(c); case (null) null };
    let kindFilter = switch (optText(args, "kind")) { case (?k) ?lower(k); case (null) null };

    let kept = Array.filter<Sub>(
      all,
      func(s) {
        let statusOk = switch (statusFilter) {
          case ("live") isLive(s);
          case ("all") true;
          case (other) statusText(s.status) == other;
        };
        let categoryOk = switch (categoryFilter) { case (?c) s.category == c; case (null) true };
        let kindOk = switch (kindFilter) {
          case (?"on-chain") s.onchain != null;
          case (?"onchain") s.onchain != null;
          case (?"off-chain") s.onchain == null;
          case (?"offchain") s.onchain == null;
          case (?_) true;
          case (null) true;
        };
        statusOk and categoryOk and kindOk;
      },
    );

    let sortBy = switch (optText(args, "sort")) { case (?t) lower(t); case (null) "renewal" };
    let sorted = Array.sort<Sub>(
      kept,
      func(a, b) : Order.Order {
        if (sortBy == "cost") {
          let ca = annualCents(a);
          let cb2 = annualCents(b);
          if (ca > cb2) #less else if (ca < cb2) #greater else #equal;
        } else {
          let da = rollForward(a.nextRenewal, a.cycle, todayDay).0;
          let db = rollForward(b.nextRenewal, b.cycle, todayDay).0;
          if (da < db) #less else if (da > db) #greater else #equal;
        };
      },
    );

    let limit = switch (optNat(args, "limit")) { case (?n) { if (n == 0) 100 else n }; case (null) 100 };
    let rows = Buffer.Buffer<Json.Json>(sorted.size());
    var monthlyTotal : Nat = 0;
    var annualTotal : Nat = 0;
    var i = 0;
    for (s in sorted.vals()) {
      if (isLive(s)) {
        monthlyTotal += monthlyCents(s);
        annualTotal += annualCents(s);
      };
      if (i < limit) rows.add(subToJson(s, todayDay, false));
      i += 1;
    };

    // Totals cover every live subscription matched, not just the rows shown.
    cb(#ok(okResult(Json.obj([
      ("count", Json.int(rows.size())),
      ("matched", Json.int(sorted.size())),
      ("live_monthly_total", Json.str(fmtMoney(monthlyTotal, "USD"))),
      ("live_annual_total", Json.str(fmtMoney(annualTotal, "USD"))),
      ("subscriptions", Json.arr(Buffer.toArray(rows))),
    ]))));
  };

  func getSubscriptionTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?id = optNat(args, "id") else return cb(#ok(errorResult("Missing or non-numeric 'id'.")));
    let ?s = ownedSub(p, id) else return cb(#ok(errorResult("No subscription " # Nat.toText(id) # " in your registry.")));
    cb(#ok(okResult(Json.obj([
      ("subscription", subToJson(s, today(), true)),
      ("to_cancel", cancelInstructions(s)),
    ]))));
  };

  func markUsedTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?id = optNat(args, "id") else return cb(#ok(errorResult("Missing or non-numeric 'id'.")));
    let ?s = ownedSub(p, id) else return cb(#ok(errorResult("No subscription " # Nat.toText(id) # " in your registry.")));
    let todayDay = today();
    let day = switch (optText(args, "on")) {
      case (?t) {
        let ?d = parseDayArg(t) else return cb(#ok(errorResult("'" # t # "' is not a date. Use 'today', 'yesterday', '-3', or 'YYYY-MM-DD'.")));
        d;
      };
      case (null) todayDay;
    };
    if (day > todayDay) return cb(#ok(errorResult("You can't have used it in the future.")));
    let updated = withEvent({ s with lastUsed = ?day }, "Used on " # fmtDate(day) # ".", Time.now());
    putSub(updated);
    cb(#ok(okResult(subResponse(updated, "Marked '" # s.name # "' used on " # fmtDate(day) # ".", todayDay))));
  };

  func cancelSubscriptionTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?id = optNat(args, "id") else return cb(#ok(errorResult("Missing or non-numeric 'id'.")));
    let ?s = ownedSub(p, id) else return cb(#ok(errorResult("No subscription " # Nat.toText(id) # " in your registry.")));
    if (s.status == #cancelled) return cb(#ok(errorResult("'" # s.name # "' is already marked cancelled (on " # (switch (s.cancelledOn) { case (?d) fmtDate(d); case (null) "an unrecorded date" }) # ").")));

    let now = Time.now();
    let todayDay = today();
    let reason = optText(args, "reason");
    let saved = annualCents(s);
    let updated = withEvent(
      {
        s with
        status = #cancelled;
        cancelledOn = ?todayDay;
        cancelReason = reason;
      },
      "Marked cancelled" # (switch (reason) { case (?r) ": " # r; case (null) "" }) # ".",
      now,
    );
    putSub(updated);

    let payload = Json.obj([
      ("message", Json.str("Marked '" # s.name # "' cancelled — " # fmtMoney(saved, s.currency) # " a year off your total. This server has not cancelled anything on your behalf; see to_cancel for what to actually do.")),
      ("annual_saving", Json.str(fmtMoney(saved, s.currency))),
      ("subscription", subToJson(updated, todayDay, false)),
      ("to_cancel", cancelInstructions(updated)),
    ]);
    cb(#ok(okResult(payload)));
  };

  func deleteSubscriptionTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let ?id = optNat(args, "id") else return cb(#ok(errorResult("Missing or non-numeric 'id'.")));
    let ?s = ownedSub(p, id) else return cb(#ok(errorResult("No subscription " # Nat.toText(id) # " in your registry.")));
    Map.delete(subsById, nhash, id);
    Map.set(subIdsByOwner, phash, p, Array.filter<Nat>(ownerIds(p), func(x) { x != id }));
    cb(#ok(okResult(Json.obj([("message", Json.str("Deleted '" # s.name # "' and its history."))]))));
  };

  // --- THE AUDIT ---

  func auditTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let todayDay = today();
    let horizon = switch (optNat(args, "days")) { case (?n) Int.abs(n); case (null) defaultHorizonDays };
    let all = ownerSubs(p);
    let live = Array.filter<Sub>(all, isLive);

    var monthlyTotal : Nat = 0;
    var annualTotal : Nat = 0;
    let byCategory : Map.Map<Text, Nat> = Map.new();
    let categoryCounts : Map.Map<Text, Nat> = Map.new();

    for (s in live.vals()) {
      monthlyTotal += monthlyCents(s);
      annualTotal += annualCents(s);
      let prior = switch (Map.get(byCategory, thash, s.category)) { case (?v) v; case (null) 0 };
      Map.set(byCategory, thash, s.category, prior + annualCents(s));
      let priorCount = switch (Map.get(categoryCounts, thash, s.category)) { case (?v) v; case (null) 0 };
      Map.set(categoryCounts, thash, s.category, priorCount + 1);
    };

    let renewals = Buffer.Buffer<Json.Json>(8);
    let trials = Buffer.Buffer<Json.Json>(4);
    let increases = Buffer.Buffer<Json.Json>(4);
    let unused = Buffer.Buffer<Json.Json>(4);
    let zombies = Buffer.Buffer<Json.Json>(4);
    let flags = Buffer.Buffer<Json.Json>(8);
    var potentialSavings : Nat = 0;

    for (s in live.vals()) {
      let (next, _) = rollForward(s.nextRenewal, s.cycle, todayDay);
      let daysOut = next - todayDay;
      if (daysOut <= horizon) {
        renewals.add(Json.obj([
          ("id", Json.int(s.id)),
          ("name", Json.str(s.name)),
          ("on", Json.str(fmtDate(next))),
          ("in_days", Json.int(daysOut)),
          ("amount", Json.str(fmtMoney(s.cents, s.currency))),
        ]));
      };

      switch (s.trialEnds) {
        case (?t) {
          let out = t - todayDay;
          if (s.status == #trial and out <= trialWarningDays) {
            trials.add(Json.obj([
              ("id", Json.int(s.id)),
              ("name", Json.str(s.name)),
              ("converts_on", Json.str(fmtDate(t))),
              ("in_days", Json.int(out)),
              ("starts_costing", Json.str(fmtMoney(s.cents, s.currency) # " " # cycleText(s.cycle))),
              ("annual_if_kept", Json.str(fmtMoney(annualCents(s), s.currency))),
            ]));
            potentialSavings += annualCents(s);
          };
        };
        case (null) {};
      };

      let first = firstPrice(s);
      if (s.cents > first) {
        // Rounding can put the two annualized figures level even when the per-cycle
        // price rose, so floor the delta at zero rather than trusting Nat math.
        let annualNow = annualCents(s);
        let annualThen = roundCents(Float.fromInt(first) * periodsPerYear(s.cycle));
        let deltaAnnual : Nat = if (annualNow > annualThen) annualNow - annualThen else 0;
        let pct = (Float.fromInt(s.cents) - Float.fromInt(first)) / Float.fromInt(first) * 100.0;
        increases.add(Json.obj([
          ("id", Json.int(s.id)),
          ("name", Json.str(s.name)),
          ("was", Json.str(fmtMoney(first, s.currency))),
          ("now", Json.str(fmtMoney(s.cents, s.currency))),
          ("increase_pct", Json.float(Float.fromInt(Float.toInt(pct * 10.0)) / 10.0)),
          ("extra_per_year", Json.str(fmtMoney(deltaAnnual, s.currency))),
        ]));
      };

      let idleSince = switch (s.lastUsed) { case (?d) d; case (null) s.startedOn };
      let idleDays = todayDay - idleSince;
      if (idleDays >= unusedAfterDays) {
        unused.add(Json.obj([
          ("id", Json.int(s.id)),
          ("name", Json.str(s.name)),
          ("last_used", switch (s.lastUsed) { case (?d) Json.str(fmtDate(d)); case (null) Json.nullable() }),
          ("idle_days", Json.int(idleDays)),
          ("never_recorded_as_used", Json.bool(s.lastUsed == null)),
          ("annual_cost", Json.str(fmtMoney(annualCents(s), s.currency))),
        ]));
        potentialSavings += annualCents(s);
      };
    };

    // A cancelled subscription whose allowance is still standing is the one
    // failure mode unique to on-chain billing: you stopped the service and
    // left the permission behind.
    for (s in all.vals()) {
      if (not isLive(s)) {
        switch (s.onchain) {
          case (?o) {
            switch (o.lastAllowance) {
              case (?a) {
                if (a > 0) {
                  zombies.add(Json.obj([
                    ("id", Json.int(s.id)),
                    ("name", Json.str(s.name)),
                    ("status", Json.str(statusText(s.status))),
                    ("spender", Json.str(Principal.toText(o.spender))),
                    ("ledger", Json.str(o.ledger)),
                    ("standing_allowance_raw", Json.int(a)),
                    ("last_checked_at_ns", switch (o.lastCheckedAt) { case (?t) Json.int(t); case (null) Json.nullable() }),
                    ("action", Json.str("Revoke: icrc2_approve with spender = " # Principal.toText(o.spender) # " and amount = 0, signed by " # Principal.toText(o.account) # ".")),
                  ]));
                };
              };
              case (null) {};
            };
          };
          case (null) {};
        };
      };
    };

    let overlaps = Buffer.Buffer<Json.Json>(4);
    for ((cat, count) in Map.entries(categoryCounts)) {
      if (count > 1 and cat != "uncategorized") {
        let spend = switch (Map.get(byCategory, thash, cat)) { case (?v) v; case (null) 0 };
        overlaps.add(Json.obj([
          ("category", Json.str(cat)),
          ("subscriptions", Json.int(count)),
          ("annual_spend", Json.str(fmtMoney(spend, "USD"))),
        ]));
      };
    };

    let categories = Buffer.Buffer<Json.Json>(8);
    for ((cat, spend) in Map.entries(byCategory)) {
      categories.add(Json.obj([
        ("category", Json.str(cat)),
        ("annual", Json.str(fmtMoney(spend, "USD"))),
        ("share_pct", Json.float(if (annualTotal == 0) 0.0 else Float.fromInt(Float.toInt(Float.fromInt(spend) / Float.fromInt(annualTotal) * 1000.0)) / 10.0)),
      ]));
    };

    if (trials.size() > 0) flags.add(Json.str(Nat.toText(trials.size()) # " trial(s) convert to paid within " # Int.toText(trialWarningDays) # " days."));
    if (unused.size() > 0) flags.add(Json.str(Nat.toText(unused.size()) # " subscription(s) unused for " # Int.toText(unusedAfterDays) # "+ days."));
    if (increases.size() > 0) flags.add(Json.str(Nat.toText(increases.size()) # " price increase(s) since you signed up."));
    if (overlaps.size() > 0) flags.add(Json.str(Nat.toText(overlaps.size()) # " category(ies) with more than one active subscription."));
    if (zombies.size() > 0) flags.add(Json.str(Nat.toText(zombies.size()) # " cancelled subscription(s) still holding a standing allowance — revoke them."));
    if (flags.size() == 0 and live.size() > 0) flags.add(Json.str("Nothing flagged. Every subscription is used, priced as expected, and renewing as scheduled."));
    if (live.size() == 0) flags.add(Json.str("No live subscriptions tracked yet. Add one with add_subscription."));

    let audit = Json.obj([
      ("as_of", Json.str(fmtDate(todayDay))),
      ("horizon_days", Json.int(horizon)),
      ("live_count", Json.int(live.size())),
      ("monthly_total", Json.str(fmtMoney(monthlyTotal, "USD"))),
      ("annual_total", Json.str(fmtMoney(annualTotal, "USD"))),
      ("by_category", Json.arr(Buffer.toArray(categories))),
      ("renewing_soon", Json.arr(Buffer.toArray(renewals))),
      ("trials_converting", Json.arr(Buffer.toArray(trials))),
      ("price_increases", Json.arr(Buffer.toArray(increases))),
      ("unused", Json.arr(Buffer.toArray(unused))),
      ("category_overlap", Json.arr(Buffer.toArray(overlaps))),
      ("standing_allowances_on_cancelled", Json.arr(Buffer.toArray(zombies))),
      ("potential_annual_savings", Json.str(fmtMoney(potentialSavings, "USD"))),
      ("flags", Json.arr(Buffer.toArray(flags))),
      ("note", Json.str("Totals mix currencies as if they were one; if you track more than one currency, read the per-subscription figures. Nothing here cancels anything — cancel_subscription records your decision and returns the steps.")),
    ]);
    cb(#ok(okResult(Json.obj([("audit", audit)]))));
  };

  // --- LIVE ALLOWANCE READS ---

  func ledgerSymbolDecimals(id : Text) : async (Text, Nat) {
    switch (Map.get(ledgerMeta, thash, id)) {
      case (?m) m;
      case (null) {
        try {
          let sym = await ledgerOf(id).icrc1_symbol();
          let dec = await ledgerOf(id).icrc1_decimals();
          let m = (sym, Nat8.toNat(dec));
          Map.set(ledgerMeta, thash, id, m);
          m;
        } catch (_) {
          ("tokens", 0);
        };
      };
    };
  };

  func fmtTokens(raw : Nat, symbol : Text, decimals : Nat) : Text {
    if (decimals == 0) return Nat.toText(raw) # " " # symbol;
    var scale : Nat = 1;
    var i = 0;
    while (i < decimals) { scale *= 10; i += 1 };
    let whole = raw / scale;
    var fracText = Nat.toText(raw % scale);
    // Left-pad the fraction to `decimals` digits.
    while (fracText.size() < decimals) { fracText := "0" # fracText };
    Nat.toText(whole) # "." # fracText # " " # symbol;
  };

  func checkAllowancesTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?p = requireAuth(auth, cb) else return;
    let todayDay = today();
    let all = ownerSubs(p);

    let targets = switch (optNat(args, "id")) {
      case (?id) {
        let ?s = ownedSub(p, id) else return cb(#ok(errorResult("No subscription " # Nat.toText(id) # " in your registry.")));
        if (s.onchain == null) return cb(#ok(errorResult("'" # s.name # "' is an off-chain subscription — there is no allowance to read. Only subscriptions registered with a spender principal have one.")));
        [s];
      };
      case (null) Array.filter<Sub>(all, func(s) { s.onchain != null });
    };

    if (targets.size() == 0) {
      return cb(#ok(okResult(Json.obj([
        ("checked", Json.int(0)),
        ("allowances", Json.arr([])),
        ("note", Json.str("No on-chain subscriptions tracked. Register one by passing 'spender' to add_subscription — then this reads the live allowance off the ledger.")),
      ]))));
    };

    let rows = Buffer.Buffer<Json.Json>(targets.size());
    var checked = 0;

    for (s in targets.vals()) {
      switch (s.onchain) {
        case (?o) {
          try {
            let res = await ledgerOf(o.ledger).icrc2_allowance({
              account = { owner = o.account; subaccount = null };
              spender = { owner = o.spender; subaccount = null };
            });
            let (symbol, decimals) = await ledgerSymbolDecimals(o.ledger);
            let previous = o.lastAllowance;
            let now = Time.now();
            let updated = {
              s with
              onchain = ?{ o with lastAllowance = ?res.allowance; lastCheckedAt = ?now };
            };
            putSub(updated);
            checked += 1;

            let changeNote = switch (previous) {
              case (?prev) {
                if (prev == res.allowance) "Unchanged since last check." else if (res.allowance > prev) "Increased since last check — someone re-approved." else "Decreased since last check — consistent with a pull against it.";
              };
              case (null) "First reading.";
            };
            let concern = if (res.allowance == 0) {
              "None: nothing can be pulled under this approval.";
            } else if (not isLive(s)) {
              "Open allowance on a subscription you are not paying for. Revoke it.";
            } else {
              "Open, as expected for a live subscription. This is a standing permission, not a charge.";
            };

            rows.add(Json.obj([
              ("id", Json.int(s.id)),
              ("name", Json.str(s.name)),
              ("status", Json.str(statusText(s.status))),
              ("ledger", Json.str(o.ledger)),
              ("account", Json.str(Principal.toText(o.account))),
              ("spender", Json.str(Principal.toText(o.spender))),
              ("allowance", Json.str(fmtTokens(res.allowance, symbol, decimals))),
              ("allowance_raw", Json.int(res.allowance)),
              ("expires_at_ns", switch (res.expires_at) { case (?e) Json.int(Nat64.toNat(e)); case (null) Json.nullable() }),
              ("since_last_check", Json.str(changeNote)),
              ("concern", Json.str(concern)),
            ]));
          } catch (e) {
            rows.add(Json.obj([
              ("id", Json.int(s.id)),
              ("name", Json.str(s.name)),
              ("ledger", Json.str(o.ledger)),
              ("error", Json.str("Ledger call failed: " # Error.message(e) # ". The stored reading was left untouched.")),
            ]));
          };
        };
        case (null) {};
      };
    };

    cb(#ok(okResult(Json.obj([
      ("checked", Json.int(checked)),
      ("as_of", Json.str(fmtDate(todayDay))),
      ("allowances", Json.arr(Buffer.toArray(rows))),
      ("note", Json.str("Read-only. An allowance is permission to pull, not money already taken — and only the account owner can revoke one.")),
    ]))));
  };

  // --- SDK CONFIG & HTTP WIRING ---

  transient let mcpConfig : McpTypes.McpConfig = {
    self = Principal.fromActor(self);
    allowanceUrl = null;
    serverInfo = {
      name = "subscription-auditor";
      title = "Subscription Auditor";
      version = "0.1.0";
    };
    resources = [];
    resourceReader = func(uri) { Map.get(appContext.resourceContents, thash, uri) };
    tools = tools;
    toolImplementations = [
      ("add_subscription", addSubscriptionTool),
      ("update_subscription", updateSubscriptionTool),
      ("list_subscriptions", listSubscriptionsTool),
      ("get_subscription", getSubscriptionTool),
      ("mark_used", markUsedTool),
      ("cancel_subscription", cancelSubscriptionTool),
      ("audit", auditTool),
      ("check_allowances", checkAllowancesTool),
      ("delete_subscription", deleteSubscriptionTool),
    ];
    beacon = ?beaconContext;
  };

  transient let mcpServer = Mcp.createServer(mcpConfig);

  private func _create_http_context() : HttpHandler.Context {
    return {
      self = Principal.fromActor(self);
      active_streams = appContext.activeStreams;
      mcp_server = mcpServer;
      streaming_callback = http_request_streaming_callback;
      auth = ?authContext;
      http_asset_cache = ?http_assets.cache;
      mcp_path = ?"/mcp";
    };
  };

  public query func http_request(req : SrvTypes.HttpRequest) : async SrvTypes.HttpResponse {
    let ctx : HttpHandler.Context = _create_http_context();
    switch (HttpHandler.http_request(ctx, req)) {
      case (?mcpResponse) { mcpResponse };
      case (null) {
        if (req.url == "/") {
          // Query responses need certification on the non-raw gateway; punt to an
          // update call, which is exempt.
          {
            status_code = 204;
            headers = [];
            body = Blob.fromArray([]);
            upgrade = ?true;
            streaming_strategy = null;
          };
        } else {
          {
            status_code = 404;
            headers = [];
            body = Blob.fromArray([]);
            upgrade = null;
            streaming_strategy = null;
          };
        };
      };
    };
  };

  public shared func http_request_update(req : SrvTypes.HttpRequest) : async SrvTypes.HttpResponse {
    let ctx : HttpHandler.Context = _create_http_context();
    switch (await HttpHandler.http_request_update(ctx, req)) {
      case (?res) { res };
      case (null) {
        if (req.url == "/") {
          {
            status_code = 200;
            headers = [("Content-Type", "text/html")];
            body = Text.encodeUtf8("<h1>Subscription Auditor MCP Server</h1><p>Every recurring charge in one registry your agent can read: renewal and trial warnings, price-increase detection, unused-subscription flags, and a live read of the ICRC-2 allowances standing against your account. Read-only where money is concerned — it never approves, transfers, or cancels. MCP endpoint at <code>/mcp</code>. Authenticate with an <code>x-api-key</code> header.</p>");
            upgrade = null;
            streaming_strategy = null;
          };
        } else {
          {
            status_code = 404;
            headers = [];
            body = Blob.fromArray([]);
            upgrade = null;
            streaming_strategy = null;
          };
        };
      };
    };
  };

  public query func http_request_streaming_callback(token : HttpTypes.StreamingToken) : async ?HttpTypes.StreamingCallbackResponse {
    let ctx : HttpHandler.Context = _create_http_context();
    return HttpHandler.http_request_streaming_callback(ctx, token);
  };

  system func preupgrade() {
    stable_http_assets := HttpAssets.preupgrade(http_assets);
  };

  system func postupgrade() {
    HttpAssets.postupgrade(http_assets);
  };

  /// Mint a stable API key bound to the caller's principal.
  /// The raw key is returned once and never stored in plaintext.
  public shared (msg) func create_my_api_key(name : Text, scopes : [Text]) : async Text {
    return await ApiKey.create_my_api_key(authContext, msg.caller, name, scopes);
  };
};
