# This file normally lists modules for Azure Functions' "managed dependencies"
# feature to auto-install on cold start. Flex Consumption does NOT support
# managed dependencies -- and this app deliberately avoids external modules
# anyway (Blob Storage access is done via raw REST calls signed with built-in
# .NET crypto, not Az.Storage). Left empty on purpose -- do not add modules
# here, they will not be installed.
@{
}
