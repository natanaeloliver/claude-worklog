# Demand PROJ-042 — Implement user authentication

> **Type:** feature
> **Sprint:** Sprint2026.S11
> **Owner:** jane.doe
> **Created:** 2026-06-01

---

## Current Status

| Phase | Status |
|-------|--------|
| Analysis | done |
| Implementation | in progress |
| Validation | pending |
| Delivery | pending |

> **Legend:** pending · in progress · done · blocked · n/a

---

## Repositories

- backend
- docs

---

## Description

Add JWT-based authentication to the REST API. Users must log in with email/password
to receive a token. All protected endpoints must validate the token on each request.

---

## Business Context

Currently the API has no authentication. Any client can call any endpoint.
Security audit (ticket SEC-007) flagged this as a critical gap.
This demand implements the minimum required: login endpoint + token validation middleware.

---

## Data Flow / Architecture

```
Client
  └─ POST /auth/login  →  validate credentials  →  return JWT
  └─ GET /api/*        →  middleware validates JWT  →  forward or 401
```

---

## Artifacts

| Artifact | Repository | Status |
|----------|------------|--------|
| `src/auth/login.ts` | backend | done |
| `src/middleware/auth.ts` | backend | in progress |
| `tests/auth.test.ts` | backend | pending |
| `docs/authentication.md` | docs | pending |

---

## Next Steps

- [ ] Complete `auth.ts` middleware — token expiry check not yet implemented
- [ ] Write integration tests for protected endpoints
- [ ] Update API docs with authentication section

---

## Technical Decisions

| Decision | Rationale | Date |
|----------|-----------|------|
| Use JWT (not sessions) | Stateless — no session store needed for current scale | 2026-06-01 |
| 1h token expiry | Balance between security and UX; refresh tokens deferred to SEC-012 | 2026-06-02 |

---

## Session Log

## 2026-06-01 jane.doe

**Tests performed:** Verified that POST /auth/login returns 200 with valid credentials and 401 with invalid ones. Token decode confirmed correct payload structure.

**Files consulted:** `src/models/user.ts`, existing endpoint patterns in `src/routes/`

**Logic understood:** User passwords stored as bcrypt hashes. Login flow: find user by email → compare hash → sign JWT with user.id and role.

**Files created:** `src/auth/login.ts` (login endpoint), `src/auth/token.ts` (sign/verify helpers)

**Conclusions:** Login endpoint works. Next session: implement middleware and protect existing endpoints.

Repos: backend

## 2026-06-02 jane.doe

**Tests performed:** Middleware applied to `/api/users` — returns 401 without token, 200 with valid token. Expired token correctly returns 401.

**Files consulted:** `src/middleware/`, Express docs for middleware chaining

**Files created/modified:** `src/middleware/auth.ts` (partial — expiry check TODO)

**Conclusions:** Basic flow works. Token expiry check needs `iat`+`exp` validation — blocked by question on refresh token scope (deferred to SEC-012).

Repos: backend
