@echo off
setlocal enabledelayedexpansion
REM devclaw.cmd - OpenClaw in the Microsoft Cloud (Windows)
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
echo   Logged in. Run 'devclaw up' to deploy.
echo.
exit /b 0

:up
echo.
echo   Deploying OpenClaw to Azure...
call azd up
if errorlevel 1 (
    REM Check if the error was a storage policy violation
    echo.
    echo   Deployment failed. Common fixes:
    echo.
    echo   - "RequestDisallowedByPolicy" on a storage account?
    echo     Your subscription blocks shared-key storage. Run:
    echo       azd env set SKIP_STORAGE true
    echo       devclaw up
    echo     Trade-off: chat sessions won't persist across restarts.
    echo.
    echo   - "InvalidTemplateDeployment" on OpenAI model?
    echo     Your region may not have the model SKU. Run:
    echo       azd env set AZURE_OPENAI_LOCATION eastus2
    echo       devclaw up
    echo.
    exit /b 1
)
echo.
echo   OpenClaw deployed! Run 'devclaw test' to verify.
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
REM Clean up Entra app registrations before destroying Azure resources
REM NOTE: 'az' is az.cmd on Windows - must use CALL or outer batch exits
for /f "tokens=*" %%i in ('call azd env get-value BOT_APP_ID 2^>nul') do (
    echo   Deleting bot app registration: %%i
    call az ad app delete --id %%i 2>nul
)
for /f "tokens=*" %%i in ('call azd env get-value EASYAUTH_APP_ID 2^>nul') do (
    echo   Deleting Easy Auth app registration: %%i
    call az ad app delete --id %%i 2>nul
)
call azd down --force --purge
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
for /f "tokens=*" %%a in ('az containerapp show --name %APP% --resource-group %RG% --query "properties.configuration.ingress.fqdn" -o tsv 2^>nul') do set "FQDN=%%a"
echo.
echo   devclaw
echo   --------
echo   App:     %APP%
echo   Status:  %STATUS%
echo   URL:     https://%FQDN%
echo   RG:      %RG%
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
) else if "%STATUS%"=="RunningAtMaxScale" (
    echo   Container: Running
) else (
    echo   Container: %STATUS% - wait or check 'devclaw logs'
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
echo   Deployed! Run 'devclaw test' to verify.
echo.
exit /b 0

:teams
echo.
echo   Microsoft Teams Setup (optional add-on)
echo   ---------------------------------------
echo.

REM Get bot name and FQDN from the deployment
for /f "tokens=*" %%i in ('azd env get-value HOST_FQDN 2^>nul') do set "FQDN=%%i"
for /f "tokens=*" %%i in ('azd env get-value BOT_APP_ID 2^>nul') do set "BOT_ID=%%i"
for /f "tokens=*" %%i in ('azd env get-value AZURE_RESOURCE_GROUP 2^>nul') do set "RG=%%i"
for /f "tokens=*" %%i in ('azd env get-value ENABLE_TEAMS 2^>nul') do set "ENABLE_TEAMS_FLAG=%%i"

REM Fallback: derive RG from env name if AZURE_RESOURCE_GROUP not set
if "%RG%"=="" (
    for /f "tokens=*" %%i in ('azd env get-value AZURE_ENV_NAME 2^>nul') do set "ENV_NAME=%%i"
    if not "!ENV_NAME!"=="" set "RG=rg-!ENV_NAME!"
)

REM Teams is opt-in. If no bot exists yet, offer to enable + re-provision.
if "%BOT_ID%"=="" (
    echo   Teams is an optional add-on and isn't enabled for this deployment yet.
    echo   Enabling it will create an Entra ID app registration + Azure Bot
    echo   resource, then re-provision so the container app picks up the creds.
    echo.
    set /p TEAMS_CONFIRM="  Enable Teams now? [y/N]: "
    if /i not "!TEAMS_CONFIRM!"=="y" (
        echo   Cancelled.
        echo.
        exit /b 0
    )
    if /i not "%ENABLE_TEAMS_FLAG%"=="true" (
        call azd env set ENABLE_TEAMS true
        echo   ENABLE_TEAMS=true saved to azd env.
    )
    echo   Re-provisioning (creates bot app reg + Azure Bot + Teams channel)...
    echo.
    call azd provision
    for /f "tokens=*" %%i in ('azd env get-value BOT_APP_ID 2^>nul') do set "BOT_ID=%%i"
    if "!BOT_ID!"=="" (
        echo   Provisioning didn't create a bot app registration.
        echo   Check the preprovision hook output above for tenant policy errors.
        exit /b 1
    )
    echo.
    echo   Redeploying app so MSTEAMS_* env vars take effect...
    call azd deploy
    echo.
)

REM Find the bot resource name in the resource group
for /f "tokens=*" %%i in ('az resource list --resource-group %RG% --resource-type "Microsoft.BotService/botServices" --query "[0].name" -o tsv 2^>nul') do set "BOT_NAME=%%i"

if "%BOT_NAME%"=="" (
    echo   No Azure Bot found in %RG% even after provisioning.
    echo   Check 'azd provision' output for errors.
    exit /b 1
)

echo   Bot:      %BOT_NAME%
echo   Endpoint: https://%FQDN%/api/messages
echo.

REM Enable Teams channel via REST API (az bot msteams hangs in batch scripts)
echo   Enabling Teams channel...
for /f "tokens=*" %%i in ('az account show --query id -o tsv 2^>nul') do set "SUB_ID=%%i"
echo. | az rest --method PUT --url "https://management.azure.com/subscriptions/%SUB_ID%/resourceGroups/%RG%/providers/Microsoft.BotService/botServices/%BOT_NAME%/channels/MsTeamsChannel?api-version=2022-09-15" --body "{\"location\":\"global\",\"properties\":{\"channelName\":\"MsTeamsChannel\",\"properties\":{\"isEnabled\":true}}}" -o none 2>nul
echo   Teams channel ready.

REM Build Teams app package
echo   Building Teams app package...
if not exist "teams\package" mkdir "teams\package"
powershell -Command "(Get-Content teams\manifest.json) -replace 'APP_ID_PLACEHOLDER','%BOT_ID%' | Set-Content teams\package\manifest.json"

if not exist "teams\package\color.png" (
    echo   WARNING: teams\package\color.png missing - add a 192x192 PNG icon
)
if not exist "teams\package\outline.png" (
    echo   WARNING: teams\package\outline.png missing - add a 32x32 PNG icon
)

REM Create ZIP (use pwsh for reliable Compress-Archive support)
pushd "%~dp0"
pwsh -NoProfile -Command "Compress-Archive -LiteralPath 'teams/package/manifest.json','teams/package/color.png','teams/package/outline.png' -DestinationPath 'teams/openclaw-teams-app.zip' -Force" 2>nul
popd
echo   Package: teams\openclaw-teams-app.zip
echo.
echo   Install in Teams:
echo     Teams ^> Apps ^> Manage your apps ^> Upload a custom app
echo     Select: teams\openclaw-teams-app.zip
echo     Add ^> DM the bot to test
echo.
exit /b 0

:help
echo.
echo   devclaw - OpenClaw in the Microsoft Cloud
echo.
echo   Getting started:
echo     devclaw up         Deploy OpenClaw to Azure
echo     devclaw test       Verify it's working
echo.
echo   Channels:
echo     devclaw teams      Add Microsoft Teams integration (optional add-on)
echo.
echo   Control:
echo     devclaw start      Start the agent
echo     devclaw stop       Stop the agent (state preserved)
echo     devclaw restart    Restart the agent
echo     devclaw status     Check agent status
echo     devclaw logs       Stream live logs
echo     devclaw deploy     Rebuild and deploy after code changes
echo.
echo   Cleanup:
echo     devclaw down       Delete all Azure resources
echo.
echo   Account:
echo     devclaw login      Switch Azure account
echo.
exit /b 0
