@echo off
REM msftclaw.cmd - OpenClaw in the Microsoft Cloud (Windows)
REM Wraps the bash script for cmd/PowerShell use
set "AZURE_CONFIG_DIR=%~dp0.azure"
set "COMMAND=%1"
if "%COMMAND%"=="" set "COMMAND=status"

where azd >nul 2>&1
if errorlevel 1 (
    echo   Azure Developer CLI [azd] not found.
    echo   Install: https://aka.ms/azd-install
    exit /b 1
)
where az >nul 2>&1
if errorlevel 1 (
    echo   Azure CLI [az] not found.
    echo   Install: https://aka.ms/install-azure-cli
    exit /b 1
)

if "%COMMAND%"=="login" goto :login
if "%COMMAND%"=="up" goto :up
if "%COMMAND%"=="down" goto :down
if "%COMMAND%"=="start" goto :start
if "%COMMAND%"=="stop" goto :stop
if "%COMMAND%"=="restart" goto :restart
if "%COMMAND%"=="status" goto :status
if "%COMMAND%"=="logs" goto :logs
if "%COMMAND%"=="test" goto :test
if "%COMMAND%"=="deploy" goto :deploy
if "%COMMAND%"=="teams" goto :teams
goto :help

:login
echo.
echo   Logging into Azure...
call az login
call azd auth login 2>nul
echo   Logged in. Run 'msftclaw up' to deploy.
echo.
exit /b 0

:up
echo.
echo   Deploying OpenClaw to Azure...
call azd up
echo.
echo   OpenClaw deployed! Run 'msftclaw test' to verify.
echo.
exit /b 0

:down
echo.
echo   This will permanently delete all OpenClaw Azure resources.
set /p CONFIRM="  Are you sure? [y/N]: "
if /i not "%CONFIRM%"=="y" (
    echo   Cancelled.
    exit /b 0
)
call azd down --force --purge 2>nul
echo   All resources deleted.
echo.
exit /b 0

:start
for /f "tokens=*" %%a in ('azd env get-value AZURE_RESOURCE_GROUP 2^>nul') do set "RG=%%a"
for /f "tokens=*" %%a in ('az containerapp list --resource-group %RG% --query "[0].name" -o tsv 2^>nul') do set "APP=%%a"
echo.
echo   Starting OpenClaw...
call az containerapp update --name %APP% --resource-group %RG% --min-replicas 1 --max-replicas 1 --only-show-errors >nul
echo   OpenClaw started.
echo.
exit /b 0

:stop
for /f "tokens=*" %%a in ('azd env get-value AZURE_RESOURCE_GROUP 2^>nul') do set "RG=%%a"
for /f "tokens=*" %%a in ('az containerapp list --resource-group %RG% --query "[0].name" -o tsv 2^>nul') do set "APP=%%a"
echo.
echo   Stopping OpenClaw...
call az containerapp update --name %APP% --resource-group %RG% --min-replicas 0 --max-replicas 0 --only-show-errors >nul
echo   OpenClaw stopped. State preserved.
echo.
exit /b 0

:restart
for /f "tokens=*" %%a in ('azd env get-value AZURE_RESOURCE_GROUP 2^>nul') do set "RG=%%a"
for /f "tokens=*" %%a in ('az containerapp list --resource-group %RG% --query "[0].name" -o tsv 2^>nul') do set "APP=%%a"
for /f "tokens=*" %%a in ('az containerapp revision list --name %APP% --resource-group %RG% --query "[?properties.active].name" -o tsv 2^>nul') do set "REV=%%a"
echo.
echo   Restarting OpenClaw...
call az containerapp revision restart --name %APP% --resource-group %RG% --revision %REV% --only-show-errors >nul
echo   OpenClaw restarted.
echo.
exit /b 0

:status
for /f "tokens=*" %%a in ('azd env get-value AZURE_RESOURCE_GROUP 2^>nul') do set "RG=%%a"
for /f "tokens=*" %%a in ('az containerapp list --resource-group %RG% --query "[0].name" -o tsv 2^>nul') do set "APP=%%a"
for /f "tokens=*" %%a in ('az containerapp revision list --name %APP% --resource-group %RG% --query "[?properties.active].properties.runningState" -o tsv 2^>nul') do set "STATUS=%%a"
echo.
echo   msftclaw
echo   --------
echo   App:     %APP%
echo   Status:  %STATUS%
echo.
exit /b 0

:logs
for /f "tokens=*" %%a in ('azd env get-value AZURE_RESOURCE_GROUP 2^>nul') do set "RG=%%a"
for /f "tokens=*" %%a in ('az containerapp list --resource-group %RG% --query "[0].name" -o tsv 2^>nul') do set "APP=%%a"
echo.
echo   Streaming logs (Ctrl+C to stop)...
echo.
call az containerapp logs show --name %APP% --resource-group %RG% --follow --tail 50
exit /b 0

:test
for /f "tokens=*" %%a in ('azd env get-value AZURE_RESOURCE_GROUP 2^>nul') do set "RG=%%a"
for /f "tokens=*" %%a in ('az containerapp list --resource-group %RG% --query "[0].name" -o tsv 2^>nul') do set "APP=%%a"
for /f "tokens=*" %%a in ('az containerapp revision list --name %APP% --resource-group %RG% --query "[?properties.active].properties.runningState" -o tsv 2^>nul') do set "STATUS=%%a"
echo.
if "%STATUS%"=="Running" (
    echo   Container: Running
) else (
    echo   Container: %STATUS% - wait or check 'msftclaw logs'
)
echo.
echo   To test, open Azure Portal ^> Container App ^> Console ^> /bin/bash
echo   Then run: openclaw agent --message "Hello from the cloud!"
echo.
exit /b 0

:deploy
echo.
echo   Rebuilding and deploying OpenClaw...
call azd deploy
echo   Deployed! Run 'msftclaw test' to verify.
echo.
exit /b 0

:teams
echo.
echo   Microsoft Teams Setup
echo   ---------------------
echo.
echo   You need an Azure Bot registration:
echo     1. Go to https://portal.azure.com/#create/Microsoft.AzureBot
echo     2. Create a Single Tenant bot
echo     3. Copy the App ID, Client Secret, and Tenant ID
echo     4. Enable Microsoft Teams in the bot's Channels tab
echo.
set /p BOT_APP_ID="  Azure Bot App ID: "
set /p BOT_APP_PASSWORD="  Azure Bot Client Secret: "
set /p BOT_TENANT_ID="  Tenant ID: "
if "%BOT_APP_ID%"=="" goto :teams_missing
if "%BOT_APP_PASSWORD%"=="" goto :teams_missing
if "%BOT_TENANT_ID%"=="" goto :teams_missing
echo.
echo   Updating openclaw.json with Teams config...
node -e "const fs=require('fs');const c=JSON.parse(fs.readFileSync('src/openclaw.json'));c.channels=c.channels||{};c.channels.msteams={enabled:true,appId:'%BOT_APP_ID%',appPassword:'%BOT_APP_PASSWORD%',tenantId:'%BOT_TENANT_ID%',webhook:{port:3978,path:'/api/messages'},dmPolicy:'pairing',requireMention:true};fs.writeFileSync('src/openclaw.json',JSON.stringify(c,null,2)+'\n');"
echo   Done. Now run 'msftclaw deploy' to apply.
echo.
echo   Next steps:
echo     1. Set Azure Bot messaging endpoint to your public URL + /api/messages
echo     2. Upload teams/openclaw-teams-app.zip to Teams
echo     3. Run: msftclaw deploy
echo     4. DM the bot in Teams to test
echo.
exit /b 0

:teams_missing
echo   All three values are required.
exit /b 1

:help
echo.
echo   msftclaw - OpenClaw in the Microsoft Cloud
echo.
echo   Getting started:
echo     msftclaw up         Deploy OpenClaw to Azure
echo     msftclaw test       Verify it's working
echo.
echo   Channels:
echo     msftclaw teams      Set up Microsoft Teams integration
echo.
echo   Control:
echo     msftclaw start      Start the agent
echo     msftclaw stop       Stop the agent (state preserved)
echo     msftclaw restart    Restart the agent
echo     msftclaw status     Check agent status
echo     msftclaw logs       Stream live logs
echo     msftclaw deploy     Rebuild and deploy after code changes
echo.
echo   Cleanup:
echo     msftclaw down       Delete all Azure resources
echo.
echo   Account:
echo     msftclaw login      Switch Azure account
echo.
exit /b 0
