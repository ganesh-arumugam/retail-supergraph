# OAuth Authentication with Pre-Registered Client

## Overview

Your Apollo MCP Server uses **OAuth 2.0 with Auth0** to secure access. This ensures only authorized clients can query your GraphQL API.

## What is a "Pre-Registered Client"?

Instead of allowing any application to register itself on-the-fly, you've created a **fixed application in Auth0** with specific credentials:

- **Client ID**: `G64sNtsNTCRcNV9feUElpf00mO9bwpkg`
- **Client Secret**: A secure password for this application
- **Allowed Scopes**: `read:schema`, `execute:queries`, `introspect:schema`

Think of it like having a **dedicated API key** rather than a temporary guest pass.

## How It Works

### 1. **Authentication (Getting Access)**
When Claude Desktop connects, the wrapper script:
- Sends your Client ID and Secret to Auth0
- Auth0 verifies these credentials
- Auth0 issues a **JWT access token** (valid for 24 hours)

This uses the **Client Credentials Grant** - designed for machine-to-machine authentication where no user login is needed.

### 2. **Authorization (Using Access)**
Every request to your MCP server includes:
```
Authorization: Bearer eyJhbGc...
```

The Apollo MCP Server:
- Validates the JWT signature (ensures it's from Auth0)
- Checks the token hasn't expired
- Verifies the scopes (permissions)
- Allows or denies the request

### 3. **Token Refresh**
When the token expires (after 24 hours), the wrapper automatically:
- Requests a new token from Auth0
- Continues seamlessly without user intervention

## Security Benefits

✅ **No passwords in Claude Desktop** - Only the wrapper script has credentials  
✅ **Audit trail** - Auth0 logs all authentication attempts  
✅ **Revocable access** - Disable the client in Auth0 to immediately block access  
✅ **Scoped permissions** - Token only grants specific operations  
✅ **Industry standard** - OAuth 2.0 is used by Google, GitHub, etc.

## Why Not Dynamic Registration?

**Dynamic Registration** allows any client to create its own credentials on-the-fly. While flexible, it means:
- ❌ Unknown clients can register
- ❌ Harder to audit who has access
- ❌ More complex to revoke access

**Pre-Registered Clients** give you:
- ✅ Full control over who can access your API
- ✅ Known, auditable clients
- ✅ Simple credential management in Auth0

## Configuration Summary

Your setup:
- **OAuth Provider**: Auth0 (`dev-2rd4k1xxfpjky67u.us.auth0.com`)
- **Grant Type**: Client Credentials (machine-to-machine)
- **Token Lifetime**: 24 hours
- **Security**: JWT with RS256 signature
- **Scopes**: Fine-grained permissions for GraphQL operations

This is the **recommended approach** for internal tools and trusted applications.