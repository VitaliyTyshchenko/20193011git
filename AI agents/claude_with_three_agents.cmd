
simple 3 three agents test to shows the current date with models claude-fable-5-2 claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5
golden paths generic cmd windows

three use cases: use training data, web_fetch, web_search

"tools": [{"type": "web_fetch_20260209", "name": "web_fetch", "max_uses": 1, "allowed_domains": ["utctime.app"], "citations": {"enabled": false}}],
"tools": [{"type": "web_search_20260209", "name": "web_search", "max_uses": 1, "allowed_domains": ["utctime.app/api/now"]}],

https://platform.claude.com/docs/en/models/overview
https://platform.claude.com/docs/en/managed-agents/tools-web-restrictions

///////// use case 1 with training data ////////////

@echo off
setlocal enabledelayedexpansion


set ANTHROPIC_API_KEY=


REM Record start time (cmd only)
set start_time=%time%

REM ===== MINIMAL API TEST ACCESS =====
REM https://platform.claude.com/docs/en/api/versioning

echo [Minimal API Test]
curl -X POST https://api.anthropic.com/v1/messages ^
  -H "x-api-key: %ANTHROPIC_API_KEY%" ^
  -H "anthropic-version: 2026-10-21" ^
  -H "content-type: application/json" ^
  -d "{\"model\":\"claude-fable-5-2\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" > logsapitest.txt

curl https://api.anthropic.com/v1/models ^
  -H "x-api-key: %ANTHROPIC_API_KEY%" ^
  -H "anthropic-version: 2023-06-01" >> logsapitest.txt

 

echo API test result:
type logsapitest.txt
echo.



REM ===== AGENT 1: GET MONTH =====

echo [Agent 1: Month]
set agent1_start=%time%

(
  echo {
  echo   "model": "claude-opus-5-5",
  echo   "max_tokens": 124,
  echo   "output_config": {"effort": "low"},
  echo   "messages": [{"role": "user", "content": "What month is it now? Reply ultra-short: month name only, best guess, no explanation"}]
  echo }
) > request1.txt

set agent1_curl_start=%time%

curl -s -X POST https://api.anthropic.com/v1/messages ^
  -H "x-api-key: %ANTHROPIC_API_KEY%" ^
  -H "anthropic-version: 2026-10-21" ^
  -H "content-type: application/json" ^
  -d @request1.txt > response1.txt

call :extractanswertextfromresponsefile response1.txt monthanswertext
> response1plaintext.txt echo(!monthanswertext!

set agent1_end=%time%
echo Agent 1: %agent1_start% - %agent1_end%




REM ===== AGENT 2: GET YEAR =====

echo [Agent 2: Year]
set agent2_start=%time%

(
  echo {
  echo   "model": "claude-sonnet-5-5",
  echo   "max_tokens": 124,
  echo   "output_config": {"effort": "low"},
  echo   "messages": [{"role": "user", "content": "What year is it now? Reply ultra-short: year number only, best guess, no explanation"}]
  echo }
) > request2.txt

set agent2_curl_start=%time%

curl -s -X POST https://api.anthropic.com/v1/messages ^
  -H "x-api-key: %ANTHROPIC_API_KEY%" ^
  -H "anthropic-version: 2026-10-21" ^
  -H "content-type: application/json" ^
  -d @request2.txt > response2.txt

call :extractanswertextfromresponsefile response2.txt yearanswertext
> response2plaintext.txt echo(!yearanswertext!

set agent2_end=%time%
echo Agent 2: %agent2_start% - %agent2_end%





REM ===== AGENT 3: VALIDATE FROM AGENT 1 AGENT 2 =====

echo [Agent 3: Validate]
set agent3_start=%time%

REM Build request3.txt from text answers in response1.txt and response2.txt (extracted above)

(
  echo {
  echo   "model": "claude-haiku-5-5",
  echo   "max_tokens": 124,
  echo   "output_config": {"effort": "low"},
  echo   "messages": [{"role": "user", "content": "Agent 1 was asked the current month and answered: [!monthanswertext!]. Agent 2 was asked the current year and answered: [!yearanswertext!]. Validate each answer, decide the most likely month and year based only on these two answers, return the result, return the reason why chosen most likely. Reply ultra-short: reason why month year "}]
  echo }
) > request3.txt

set agent3_curl_start=%time%

curl -s -X POST https://api.anthropic.com/v1/messages ^
  -H "x-api-key: %ANTHROPIC_API_KEY%" ^
  -H "anthropic-version: 2026-10-21" ^
  -H "content-type: application/json" ^
  -d @request3.txt > response3.txt

call :extractanswertextfromresponsefile response3.txt validatedresulttext
> response3plaintext.txt echo(!validatedresulttext!

set agent3_end=%time%
echo Agent 3: %agent3_start% - %agent3_end%

REM Record end time
set end_time=%time%
echo.


echo ===== SUMMARY =====

echo Start: %start_time%
echo End: %end_time%
echo Agent 1 time: %agent1_start% - %agent1_end%
echo Agent 2 time: %agent2_start% - %agent2_end%
echo Agent 3 time: %agent3_start% - %agent3_end%
echo.

REM Count tokens from response files
findstr /C:"input_tokens" response1.txt
findstr /C:"output_tokens" response1.txt
findstr /C:"input_tokens" response2.txt
findstr /C:"output_tokens" response2.txt
findstr /C:"input_tokens" response3.txt
findstr /C:"output_tokens" response3.txt

echo.
echo =====
goto :eof


REM ===== SUBROUTINE: extract text answer from response file =====
REM Usage: call :extractanswertextfromresponsefile responsefile resultvariablename

:extractanswertextfromresponsefile
set "responselinetext="
for /f "usebackq delims=" %%a in ("%~1") do set "responselinetext=%%a"
if not defined responselinetext (set "%~2=NO_TEXT_RETURNED: empty response file, curl failed or no network" & exit /b)
findstr /c:"\"type\":\"text\"" "%~1" >nul && goto :extractanswertextblock
findstr /c:"\"type\":\"error\"" "%~1" >nul && goto :extractapierrormessage

REM No text block: explain why using stop_reason and thinking_tokens
set "stopreasontext=unknown"
set "stopreasontailtext=!responselinetext:*"stop_reason":"=!"
set "stopreasontailtext=!stopreasontailtext:","stop_sequence"=~!"
for /f "tokens=1 delims=~" %%b in ("!stopreasontailtext!") do set "stopreasontext=%%b"
set "thinkingtokencounttext=unknown"
set "thinkingtailtext=!responselinetext:*"thinking_tokens":=!"
for /f "tokens=1 delims=}" %%b in ("!thinkingtailtext!") do set "thinkingtokencounttext=%%b"
set "%~2=NO_TEXT_RETURNED: stop_reason=!stopreasontext!, thinking_tokens=!thinkingtokencounttext!"
if "!stopreasontext!"=="max_tokens" set "%~2=!%~2! - max_tokens used up before any text, raise max_tokens or disable thinking"
exit /b

:extractanswertextblock
set "answertailtext=!responselinetext:*"type":"text","text":"=!"
set "answertailtext=!answertailtext:"}],"container"=~!"
for /f "tokens=1 delims=~" %%b in ("!answertailtext!") do set "%~2=%%b"
exit /b

:extractapierrormessage
set "errortailtext=!responselinetext:*"message":"=!"
set "errortailtext=!errortailtext:"}=~!"
for /f "tokens=1 delims=~" %%b in ("!errortailtext!") do set "%~2=API_ERROR: %%b"
exit /b

/////////////////////////////////////////////////

///////// use case 2 with web_fetch ////////////

@echo off
setlocal enabledelayedexpansion

set ANTHROPIC_API_KEY=

REM Record start time (cmd only)
set start_time=%time%

REM ===== MINIMAL API TEST ACCESS =====
REM https://platform.claude.com/docs/en/api/versioning

echo [Minimal API Test]
curl -X POST https://api.anthropic.com/v1/messages ^
  -H "x-api-key: %ANTHROPIC_API_KEY%" ^
  -H "anthropic-version: 2026-10-21" ^
  -H "content-type: application/json" ^
  -d "{\"model\":\"claude-fable-5-2\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" > logsapitest.txt

curl https://api.anthropic.com/v1/models ^
  -H "x-api-key: %ANTHROPIC_API_KEY%" ^
  -H "anthropic-version: 2023-06-01" >> logsapitest.txt

 

echo API test result:
type logsapitest.txt
echo.



REM ===== AGENT 1: GET MONTH =====

echo [Agent 1: Month]
set agent1_start=%time%

(
  echo {
  echo   "model": "claude-opus-5-5",
  echo   "max_tokens": 124,
  echo   "output_config": {"effort": "low"},
  echo   "messages": [{"role": "user", "content": "What month is it now? Reply ultra-short: month name only, best guess, no explanation"}]
  echo }
) > request1.txt

set agent1_curl_start=%time%

curl -s -X POST https://api.anthropic.com/v1/messages ^
  -H "x-api-key: %ANTHROPIC_API_KEY%" ^
  -H "anthropic-version: 2026-10-21" ^
  -H "content-type: application/json" ^
  -d @request1.txt > response1.txt

call :extractanswertextfromresponsefile response1.txt monthanswertext
> response1plaintext.txt echo(!monthanswertext!

set agent1_end=%time%
echo Agent 1: %agent1_start% - %agent1_end%




REM ===== AGENT 2: GET YEAR =====

echo [Agent 2: Year]
set agent2_start=%time%

(
  echo {
  echo   "model": "claude-sonnet-5-5",
  echo   "max_tokens": 124,
  echo   "output_config": {"effort": "low"},
  echo   "messages": [{"role": "user", "content": "What year is it now? Reply ultra-short: year number only, best guess, no explanation"}]
  echo }
) > request2.txt

set agent2_curl_start=%time%

curl -s -X POST https://api.anthropic.com/v1/messages ^
  -H "x-api-key: %ANTHROPIC_API_KEY%" ^
  -H "anthropic-version: 2026-10-21" ^
  -H "content-type: application/json" ^
  -d @request2.txt > response2.txt

call :extractanswertextfromresponsefile response2.txt yearanswertext
> response2plaintext.txt echo(!yearanswertext!

set agent2_end=%time%
echo Agent 2: %agent2_start% - %agent2_end%





REM ===== AGENT 3: VALIDATE FROM AGENT 1 AGENT 2 =====

echo [Agent 3: Validate]
set agent3_start=%time%

REM Build request3.txt from text answers in response1.txt and response2.txt (extracted above)

(
  echo {
  echo   "model": "claude-haiku-5-5",
  echo   "max_tokens": 534,
  echo   "output_config": {"effort": "low"},
  echo   "tools": [{"type": "web_fetch_20260209", "name": "web_fetch", "max_uses": 1, "allowed_domains": ["utctime.app"], "citations": {"enabled": false}}],
  echo   "messages": [{"role": "user", "content": "Agent 1 was asked the current month and answered: [!monthanswertext!]. Agent 2 was asked the current year and answered: [!yearanswertext!]. Fetch https://utctime.app/api/now exactly once with the web_fetch tool to get the real current UTC date, then validate each answer against it and return the correct month and year with the reason. Reply ultra-short: reason why month year "}]
  echo }
) > request3.txt

set agent3_curl_start=%time%

curl -s -X POST https://api.anthropic.com/v1/messages ^
  -H "x-api-key: %ANTHROPIC_API_KEY%" ^
  -H "anthropic-version: 2026-10-21" ^
  -H "content-type: application/json" ^
  -d @request3.txt > response3.txt

call :extractanswertextfromresponsefile response3.txt validatedresulttext
> response3plaintext.txt echo(!validatedresulttext!

set agent3_end=%time%
echo Agent 3: %agent3_start% - %agent3_end%

REM Record end time
set end_time=%time%
echo.


echo ===== SUMMARY =====

echo Start: %start_time%
echo End: %end_time%
echo Agent 1 time: %agent1_start% - %agent1_end%
echo Agent 2 time: %agent2_start% - %agent2_end%
echo Agent 3 time: %agent3_start% - %agent3_end%
echo.

REM Count tokens from response files
findstr /C:"input_tokens" response1.txt
findstr /C:"output_tokens" response1.txt
findstr /C:"input_tokens" response2.txt
findstr /C:"output_tokens" response2.txt
findstr /C:"input_tokens" response3.txt
findstr /C:"output_tokens" response3.txt

echo.
echo =====
goto :eof


REM ===== SUBROUTINE: extract text answer from response file =====
REM Usage: call :extractanswertextfromresponsefile responsefile resultvariablename

:extractanswertextfromresponsefile
set "responselinetext="
for /f "usebackq delims=" %%a in ("%~1") do set "responselinetext=%%a"
if not defined responselinetext (set "%~2=NO_TEXT_RETURNED: empty response file, curl failed or no network" & exit /b)
findstr /c:"\"type\":\"text\"" "%~1" >nul && goto :extractanswertextblock
findstr /c:"\"type\":\"error\"" "%~1" >nul && goto :extractapierrormessage

REM No text block: explain why using stop_reason and thinking_tokens
set "stopreasontext=unknown"
set "stopreasontailtext=!responselinetext:*"stop_reason":"=!"
set "stopreasontailtext=!stopreasontailtext:","stop_sequence"=~!"
for /f "tokens=1 delims=~" %%b in ("!stopreasontailtext!") do set "stopreasontext=%%b"
set "thinkingtokencounttext=unknown"
set "thinkingtailtext=!responselinetext:*"thinking_tokens":=!"
for /f "tokens=1 delims=}" %%b in ("!thinkingtailtext!") do set "thinkingtokencounttext=%%b"
set "%~2=NO_TEXT_RETURNED: stop_reason=!stopreasontext!, thinking_tokens=!thinkingtokencounttext!"
if "!stopreasontext!"=="max_tokens" set "%~2=!%~2! - max_tokens used up before any text, raise max_tokens or disable thinking"
exit /b

:extractanswertextblock
set "answertailtext=!responselinetext:*"type":"text","text":"=!"
set "answertailtext=!answertailtext:"}],"container"=~!"
for /f "tokens=1 delims=~" %%b in ("!answertailtext!") do set "%~2=%%b"
exit /b

:extractapierrormessage
set "errortailtext=!responselinetext:*"message":"=!"
set "errortailtext=!errortailtext:"}=~!"
for /f "tokens=1 delims=~" %%b in ("!errortailtext!") do set "%~2=API_ERROR: %%b"
exit /b

/////////////////////////////////////////////////

///////// use case 3 with web_search ////////////


@echo off
setlocal enabledelayedexpansion




set ANTHROPIC_API_KEY=



REM Record start time (cmd only)
set start_time=%time%

REM ===== MINIMAL API TEST ACCESS =====
REM https://platform.claude.com/docs/en/api/versioning

echo [Minimal API Test]
curl -X POST https://api.anthropic.com/v1/messages ^
  -H "x-api-key: %ANTHROPIC_API_KEY%" ^
  -H "anthropic-version: 2026-10-21" ^
  -H "content-type: application/json" ^
  -d "{\"model\":\"claude-fable-5-2\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" > logsapitest.txt

curl https://api.anthropic.com/v1/models ^
  -H "x-api-key: %ANTHROPIC_API_KEY%" ^
  -H "anthropic-version: 2023-06-01" >> logsapitest.txt

 

echo API test result:
type logsapitest.txt
echo.



REM ===== AGENT 1: GET MONTH =====

echo [Agent 1: Month]
set agent1_start=%time%

(
  echo {
  echo   "model": "claude-opus-5-5",
  echo   "max_tokens": 124,
  echo   "output_config": {"effort": "low"},
  echo   "messages": [{"role": "user", "content": "What month is it now? Reply ultra-short: month name only, best guess, no explanation"}]
  echo }
) > request1.txt

set agent1_curl_start=%time%

curl -s -X POST https://api.anthropic.com/v1/messages ^
  -H "x-api-key: %ANTHROPIC_API_KEY%" ^
  -H "anthropic-version: 2026-10-21" ^
  -H "content-type: application/json" ^
  -d @request1.txt > response1.txt

call :extractanswertextfromresponsefile response1.txt monthanswertext
> response1plaintext.txt echo(!monthanswertext!

set agent1_end=%time%
echo Agent 1: %agent1_start% - %agent1_end%




REM ===== AGENT 2: GET YEAR =====

echo [Agent 2: Year]
set agent2_start=%time%

(
  echo {
  echo   "model": "claude-sonnet-5-5",
  echo   "max_tokens": 124,
  echo   "output_config": {"effort": "low"},
  echo   "messages": [{"role": "user", "content": "What year is it now? Reply ultra-short: year number only, best guess, no explanation"}]
  echo }
) > request2.txt

set agent2_curl_start=%time%

curl -s -X POST https://api.anthropic.com/v1/messages ^
  -H "x-api-key: %ANTHROPIC_API_KEY%" ^
  -H "anthropic-version: 2026-10-21" ^
  -H "content-type: application/json" ^
  -d @request2.txt > response2.txt

call :extractanswertextfromresponsefile response2.txt yearanswertext
> response2plaintext.txt echo(!yearanswertext!

set agent2_end=%time%
echo Agent 2: %agent2_start% - %agent2_end%





REM ===== AGENT 3: VALIDATE FROM AGENT 1 AGENT 2 =====

echo [Agent 3: Validate]
set agent3_start=%time%

REM Build request3.txt from text answers in response1.txt and response2.txt (extracted above)

(
  echo {
  echo   "model": "claude-haiku-5-5",
  echo   "max_tokens": 124,
  echo   "output_config": {"effort": "low"},
  echo   "tools": [{"type": "web_search_20260209", "name": "web_search", "max_uses": 1, "allowed_domains": ["utctime.app/api/now"]}],
  echo   "messages": [{"role": "user", "content": "Agent 1 was asked the current month and answered: [!monthanswertext!]. Agent 2 was asked the current year and answered: [!yearanswertext!]. Use the web_search tool exactly once to get the real current UTC date, then validate each answer against it and return the correct month and year with the reason. Reply ultra-short: reason why month year "}]
  echo }
) > request3.txt

set agent3_curl_start=%time%

curl -s -X POST https://api.anthropic.com/v1/messages ^
  -H "x-api-key: %ANTHROPIC_API_KEY%" ^
  -H "anthropic-version: 2026-10-21" ^
  -H "content-type: application/json" ^
  -d @request3.txt > response3.txt

call :extractanswertextfromresponsefile response3.txt validatedresulttext
> response3plaintext.txt echo(!validatedresulttext!

set agent3_end=%time%
echo Agent 3: %agent3_start% - %agent3_end%

REM Record end time
set end_time=%time%
echo.


echo ===== SUMMARY =====

echo Start: %start_time%
echo End: %end_time%
echo Agent 1 time: %agent1_start% - %agent1_end%
echo Agent 2 time: %agent2_start% - %agent2_end%
echo Agent 3 time: %agent3_start% - %agent3_end%
echo.

REM Count tokens from response files
findstr /C:"input_tokens" response1.txt
findstr /C:"output_tokens" response1.txt
findstr /C:"input_tokens" response2.txt
findstr /C:"output_tokens" response2.txt
findstr /C:"input_tokens" response3.txt
findstr /C:"output_tokens" response3.txt

echo.
echo =====
goto :eof


REM ===== SUBROUTINE: extract text answer from response file =====
REM Usage: call :extractanswertextfromresponsefile responsefile resultvariablename

:extractanswertextfromresponsefile
set "responselinetext="
for /f "usebackq delims=" %%a in ("%~1") do set "responselinetext=%%a"
if not defined responselinetext (set "%~2=NO_TEXT_RETURNED: empty response file, curl failed or no network" & exit /b)
findstr /c:"\"type\":\"text\"" "%~1" >nul && goto :extractanswertextblock
findstr /c:"\"type\":\"error\"" "%~1" >nul && goto :extractapierrormessage

REM No text block: explain why using stop_reason and thinking_tokens
set "stopreasontext=unknown"
set "stopreasontailtext=!responselinetext:*"stop_reason":"=!"
set "stopreasontailtext=!stopreasontailtext:","stop_sequence"=~!"
for /f "tokens=1 delims=~" %%b in ("!stopreasontailtext!") do set "stopreasontext=%%b"
set "thinkingtokencounttext=unknown"
set "thinkingtailtext=!responselinetext:*"thinking_tokens":=!"
for /f "tokens=1 delims=}" %%b in ("!thinkingtailtext!") do set "thinkingtokencounttext=%%b"
set "%~2=NO_TEXT_RETURNED: stop_reason=!stopreasontext!, thinking_tokens=!thinkingtokencounttext!"
if "!stopreasontext!"=="max_tokens" set "%~2=!%~2! - max_tokens used up before any text, raise max_tokens or disable thinking"
exit /b

:extractanswertextblock
set "answertailtext=!responselinetext:*"type":"text","text":"=!"
set "answertailtext=!answertailtext:"}],"container"=~!"
for /f "tokens=1 delims=~" %%b in ("!answertailtext!") do set "%~2=%%b"
exit /b

:extractapierrormessage
set "errortailtext=!responselinetext:*"message":"=!"
set "errortailtext=!errortailtext:"}=~!"
for /f "tokens=1 delims=~" %%b in ("!errortailtext!") do set "%~2=API_ERROR: %%b"
exit /b

//////////////////////////////////////////////////////


////////////////////////////////
////////////////////////////////

auth api  API_ERROR: x-api-key header is required

headers set  Header -H "anthropic-version: 2026-10-21" is required

errors NO_TEXT_RETURNED: stop_reason=max_tokens, thinking_tokens=75 - max_tokens used up before any text, raise max_tokens or disable thinking

without internet the model's use training data its prior guess:
June 2025. Two independent answers agree with no conflicting evidence, so this is the most likely current date based on them alone.


with internet web_search  API_ERROR: Web search is not enabled for this organization
 "tools": [{"type": "web_search_20260209", "name": "web_search", "max_uses": 1, "allowed_domains": ["utctime.app/api/now"]}],

with internet web_fetch robot.txt
"tools": [{"type": "web_fetch_20260209", "name": "web_fetch", "max_uses": 1, "allowed_domains": ["utctime.app"], "citations": {"enabled": false}}],

Couldn't verify against utctime.app: the fetch was rejected (url_not_allowed), and didn't retry due to robot.txt 
The container clock reads November 2026 UTC, so both answers are wrong: correct is **November 2026**. 
Reason: the system clock is unverified, and Agent 1 (June) and Agent 2 (2025) are both stale.

NTP https://utctime.app/api/now

utc_iso	"2026-11-16T20:50:12Z"
utc_rfc3339	"2026-11-16T20:50:12+00:00"
utc_datetime	"2026-11-16T20:50:12.018021+00:00"
unix	1794862212
unix_ms	1794862212018
day_of_week	1
day_of_year	320
week_number	47

////////////////////////////////
////////////////////////////////
