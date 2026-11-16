//+------------------------------------------------------------------+
//|                                            PostgrestTestEA.mq5   |
//|                        Copyright 2026, MetaTrader 5              |
//|                                              Version 1.00        |
//|   Diversion: CRUD smoke test against the in-cluster PostgREST    |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaTrader 5"
#property version   "1.00"
#property description "PostgREST CRUD test (POST/PATCH/GET/DELETE/GET on public.events)"

// CRUD smoke test for the PostgREST test service (namespace mt5-data):
//
//   POST   /events                 Prefer: return=representation  -> 201
//   PATCH  /events?id=eq.<id>      Prefer: return=representation  -> 200/204
//   GET    /events?id=eq.<id>                                     -> 200, one row
//   DELETE /events?id=eq.<id>                                     -> 204
//   GET    /events?id=eq.<id>                                     -> 200, []
//
// Every request/response is printed with its status code and a body snippet,
// and the run ends with a single PASS/FAIL summary line.
//
// WHY WebRequest AND NOT RAW SOCKETS (measured on build 6320):
//
// WebRequest() is whitelist-gated: the URL must appear on the terminal's
// Tools > Options > Expert Advisors > "Allow WebRequest for listed URL" list.
// MT5 stores that list ENCRYPTED in the terminal's Config/common.ini:
//
//   [Experts]
//   WebRequest=1
//   WebRequestUrl=30F5E0614504...AC24CB906ADA      (hex blob, not the URL)
//
// The value is an opaque hex blob written only by the terminal, so the list
// CANNOT be committed or hand-written from this repository: adding the URL once
// through the Options dialog is the only supported way, and it must be done in
// the profile the pod will actually read. In dev that is the HOST-mounted
// Config tree ($MT5_DATA_DIR/profile/dev/Config); in prod the profile has to be
// opened by a terminal, the URL added, and that tree uploaded to MinIO BEFORE
// it is used (the pods seed their Config from there).
//
// PROD IS UNVERIFIED: the prod overlay is headless (no KasmVNC/nginx/s6), so
// the dialog step cannot be performed inside the prod pod at all, and no run
// has shown a prod terminal accepting the blob from a seeded profile. The check
// is this EA's own log: "WebRequest ... error 4060" or 4014 means it was not
// accepted, and the HTTP test then needs a one-off UI-capable run to whitelist
// the URL beforehand.
//
// Raw MQL5 sockets were tried first and are not a way around that gate: on this
// build a plain TCP connect from the terminal to the same host:port returned
// false with GetLastError()==4014 (ERR_FUNCTION_NOT_ALLOWED) even while
// WebRequest("GET", ".../events?limit=1") answered 200 with body "[]" from the
// same terminal and the same whitelist entry. That one 200-versus-4014 run is
// why this EA speaks WebRequest, and why the socket transport it used to carry
// was deleted. WebRequest also handles HTTP/1.1 framing, chunked responses and
// Content-Length itself, so none of the manual framing code is left either.
//
// Requirement: plain HTTP only. An https:// base URL would need a trusted
// certificate inside the terminal; the service is cluster-local and
// unauthenticated by design (namespace mt5-data, no NodePort, anon role mt5).

input string InpBaseUrl = "http://postgrest.mt5-data.svc.cluster.local:3000"; // PostgREST base URL
input string InpSymbol  = "EURUSD";                                          // Symbol reported in the payload
input int    InpTimerSeconds = 2;                                            // Fallback run timer (no tick yet)

string g_host   = "";
int    g_port   = 80;
string g_prefix = "";
bool   g_done   = false;

//+------------------------------------------------------------------+
//| Split "http://host[:port][/prefix]" into its parts.               |
//+------------------------------------------------------------------+
bool ParseBaseUrl(const string url, string &host, int &port, string &prefix)
{
   string rest = url;
   StringTrimLeft(rest);
   StringTrimRight(rest);
   if(StringFind(rest, "http://") != 0)
   {
      PrintFormat("POSTGREST-TEST FAIL: InpBaseUrl must start with http:// (got '%s'); TLS is not implemented", rest);
      return(false);
   }
   rest = StringSubstr(rest, 7);
   int slash = StringFind(rest, "/");
   string authority = (slash >= 0) ? StringSubstr(rest, 0, slash) : rest;
   prefix = (slash >= 0) ? StringSubstr(rest, slash) : "";
   while(StringLen(prefix) > 1 && StringSubstr(prefix, StringLen(prefix) - 1) == "/")
      prefix = StringSubstr(prefix, 0, StringLen(prefix) - 1);
   if(StringLen(prefix) == 1)
      prefix = "";

   int colon = StringFind(authority, ":");
   if(colon >= 0)
   {
      host = StringSubstr(authority, 0, colon);
      port = (int)StringToInteger(StringSubstr(authority, colon + 1));
   }
   else
   {
      host = authority;
      port = 80;
   }
   if(StringLen(host) == 0 || port <= 0 || port > 65535)
   {
      PrintFormat("POSTGREST-TEST FAIL: cannot parse host/port out of '%s'", url);
      return(false);
   }
   return(true);
}

//+------------------------------------------------------------------+
//| Absolute URL for a request path, port omitted when it is 80.      |
//+------------------------------------------------------------------+
string BuildUrl(const string path)
{
   return("http://" + g_host + ((g_port == 80) ? "" : ":" + IntegerToString(g_port)) + g_prefix + path);
}

//+------------------------------------------------------------------+
//| One HTTP request through WebRequest().                            |
//| Returns false only when the request could not be performed at all;|
//| any HTTP status (including 4xx/5xx) is a successful call.          |
//+------------------------------------------------------------------+
bool HttpCall(const string method, const string path, const string body,
              const string extraHeaders, int &status, string &respBody)
{
   status = 0;
   respBody = "";

   const string url = BuildUrl(path);

   // WebRequest() always wants a char[] body: empty for GET/DELETE, UTF-8
   // bytes otherwise. StringToCharArray() appends a terminating NUL, which
   // must not be sent as payload.
   char data[];
   if(StringLen(body) > 0)
   {
      int len = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
      while(len > 0 && data[len - 1] == 0)
         len--;
      ArrayResize(data, len);
   }
   else
      ArrayResize(data, 0);

   string headers = extraHeaders;
   if(StringLen(body) > 0)
      headers += "Content-Type: application/json\r\n";

   char   result[];
   string resultHeaders = "";
   int code = WebRequest(method, url, headers, 5000, data, result, resultHeaders);
   if(code == -1)
   {
      // 4060 / 4014 is the whitelist gate, not a network problem.
      int err = GetLastError();
      PrintFormat("POSTGREST-TEST FAIL: WebRequest(%s %s) error %d", method, url, err);
      if(err == 4060 || err == 4014)
         PrintFormat("POSTGREST-TEST FAIL: error %d means the URL is not whitelisted - add %s in Tools > Options > Expert Advisors > Allow WebRequest for listed URL",
                     err, BuildUrl(""));
      return(false);
   }
   status = code;

   int n = ArraySize(result);
   while(n > 0 && result[n - 1] == 0)
      n--;
   respBody = (n > 0) ? CharArrayToString(result, 0, n, CP_UTF8) : "";
   return(true);
}

//+------------------------------------------------------------------+
//| Short single-line body snippet for the log.                        |
//+------------------------------------------------------------------+
string Snippet(const string body, const int maxLen = 240)
{
   string s = body;
   StringReplace(s, "\r", " ");
   StringReplace(s, "\n", " ");
   if(StringLen(s) > maxLen)
      s = StringSubstr(s, 0, maxLen) + "...";
   return(s);
}

//+------------------------------------------------------------------+
//| Extract "id" from a JSON body (first "id":<digits>).               |
//+------------------------------------------------------------------+
bool ExtractId(const string body, long &id)
{
   int key = StringFind(body, "\"id\":");
   if(key < 0)
      return(false);
   int i = key + 5;
   string digits = "";
   while(i < StringLen(body))
   {
      ushort c = StringGetCharacter(body, i);
      if(c < '0' || c > '9')
         break;
      digits += ShortToString(c);
      i++;
   }
   if(StringLen(digits) == 0)
      return(false);
   id = StringToInteger(digits);
   return(id > 0);
}

//+------------------------------------------------------------------+
//| The whole CRUD sequence. Returns true only if every step matched. |
//+------------------------------------------------------------------+
bool RunCrud()
{
   bool ok = true;
   int status = 0;
   string resp = "";
   string failures = "";

   const string events = "/events";

   // 1) CREATE ------------------------------------------------------
   string createBody = StringFormat("{\"source\":\"PostgrestTestEA\",\"action\":\"create\",\"payload\":{\"symbol\":\"%s\",\"build\":%d}}",
                                    InpSymbol, (int)TerminalInfoInteger(TERMINAL_BUILD));
   if(!HttpCall("POST", events, createBody, "Prefer: return=representation\r\n", status, resp) || status != 201)
   {
      ok = false;
      failures += StringFormat("POST=%d ", status);
   }
   PrintFormat("POSTGREST POST %s -> HTTP %d | %s", BuildUrl(events), status, Snippet(resp));

   long id = 0;
   if(!ExtractId(resp, id))
   {
      Print("POSTGREST-TEST FAIL: POST response carried no id; aborting the sequence");
      return(false);
   }
   PrintFormat("POSTGREST created id=%I64d", id);

   // 2) UPDATE ------------------------------------------------------
   string patchBody = StringFormat("{\"action\":\"update\",\"payload\":{\"symbol\":\"%s\",\"build\":%d,\"phase\":\"updated\"}}",
                                   InpSymbol, (int)TerminalInfoInteger(TERMINAL_BUILD));
   string patchPath = events + "?id=eq." + IntegerToString(id);
   if(!HttpCall("PATCH", patchPath, patchBody, "Prefer: return=representation\r\n", status, resp) ||
      (status != 200 && status != 204))
   {
      ok = false;
      failures += StringFormat("PATCH=%d ", status);
   }
   PrintFormat("POSTGREST PATCH %s -> HTTP %d | %s", BuildUrl(patchPath), status, Snippet(resp));

   // 3) READ --------------------------------------------------------
   string getPath = events + "?id=eq." + IntegerToString(id);
   if(!HttpCall("GET", getPath, "", "", status, resp) || status != 200 ||
      StringFind(resp, "\"phase\": \"updated\"") < 0)
   {
      ok = false;
      failures += StringFormat("GET=%d ", status);
   }
   PrintFormat("POSTGREST GET %s -> HTTP %d | %s", BuildUrl(getPath), status, Snippet(resp));

   // 4) DELETE ------------------------------------------------------
   if(!HttpCall("DELETE", getPath, "", "", status, resp) || status != 204)
   {
      ok = false;
      failures += StringFormat("DELETE=%d ", status);
   }
   PrintFormat("POSTGREST DELETE %s -> HTTP %d", BuildUrl(getPath), status);

   // 5) READ AGAIN --------------------------------------------------
   if(!HttpCall("GET", getPath, "", "", status, resp) || status != 200)
   {
      ok = false;
      failures += StringFormat("GET-after-delete=%d ", status);
   }
   string trimmed = resp;
   StringTrimLeft(trimmed);
   StringTrimRight(trimmed);
   if(trimmed != "[]")
      ok = false;
   PrintFormat("POSTGREST GET %s (after delete) -> HTTP %d | %s", BuildUrl(getPath), status, Snippet(resp));

   if(ok)
      PrintFormat("POSTGREST-TEST PASS: create/update/read/delete/read on %s (id=%I64d, %d rows left)",
                  BuildUrl(events), id, (trimmed == "[]") ? 0 : 1);
   else
      PrintFormat("POSTGREST-TEST FAIL: %s", failures);
   return(ok);
}

//+------------------------------------------------------------------+
//| Run exactly once, whatever fires first (timer or tick).           |
//+------------------------------------------------------------------+
void RunOnce()
{
   if(g_done)
      return;
   g_done = true;
   EventKillTimer();
   RunCrud();
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(!ParseBaseUrl(InpBaseUrl, g_host, g_port, g_prefix))
      return(INIT_PARAMETERS_INCORRECT);

   if(!SymbolSelect(InpSymbol, true))
      PrintFormat("POSTGREST-TEST WARN: SymbolSelect(%s) failed, continuing", InpSymbol);

   PrintFormat("PostgrestTestEA: init base=%s host=%s port=%d prefix='%s' symbol=%s build=%d",
               InpBaseUrl, g_host, g_port, g_prefix, InpSymbol, (int)TerminalInfoInteger(TERMINAL_BUILD));

   // A tick is not guaranteed (closed market, no symbol select), so the timer
   // guarantees the run; g_done makes the two paths race-free.
   EventSetTimer((InpTimerSeconds > 0) ? InpTimerSeconds : 2);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   PrintFormat("PostgrestTestEA: OnDeinit reason=%d", reason);
}

//+------------------------------------------------------------------+
void OnTimer()
{
   RunOnce();
}

//+------------------------------------------------------------------+
void OnTick()
{
   RunOnce();
}
//+------------------------------------------------------------------+
