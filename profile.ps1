# Runs once per cold start, before any function invocation in this app.
# Deliberately minimal -- this app doesn't use the Az PowerShell module, so
# none of the usual Az-context boilerplate (Disable-AzContextAutosave, etc.)
# belongs here.

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}
