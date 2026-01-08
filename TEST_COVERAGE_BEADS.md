# Test Coverage Beads - Financial Advisor Project

**Created:** 2026-01-05
**Purpose:** Comprehensive test coverage for all pathways in backend (Python/FastAPI) and iOS (Swift) repos

## Summary

Created **15 test beads** across both repositories to systematically test all critical pathways, edge cases, and integration points.

### iOS Tests: 7 Beads

**Priority 1 (Critical - 4 beads):**
1. `ios-5at` - IMAPService tests
2. `ios-cen` - SettingsViewModel tests
3. `ios-def` - Email sync workflow integration tests
4. `ios-c4l` - Edge case and error handling tests

**Priority 2 (High - 2 beads):**
5. `ios-x0v` - View logic and ViewModel tests
6. `ios-fsj` - Performance tests

**Priority 3 (Medium - 1 bead):**
7. `ios-f9d` - Snapshot tests for UI consistency

### Backend Tests: 8 Beads

**Priority 1 (Critical - 6 beads):**
1. `backend-hcc` - BNPL detection service tests
2. `backend-t6i` - Email parsing service tests
3. `backend-amw` - API endpoint integration tests
4. `backend-oxn` - Database models and operations tests
5. `backend-0c8` - Authentication and JWT tests
6. `backend-vxi` - Gmail API integration tests

**Priority 2 (High - 2 beads):**
7. `backend-cq0` - End-to-end user workflow tests
8. `backend-osc` - Performance and load tests

---

## iOS Test Beads (Detailed)

### ios-5at: Add comprehensive tests for IMAPService ⚡ P1

**Status:** Blocked (awaiting IMAPService implementation)

**Scope:**
- Connection establishment (success/failure scenarios)
- Credential validation
- Email fetching with various filters
- Error handling (network errors, auth failures, timeout)
- Disconnect and cleanup
- Mock IMAP responses using MockIMAPService pattern

**Coverage Goals:**
- Happy path: successful connection and email fetch
- Error paths: invalid credentials, network errors
- Edge cases: empty inbox, malformed emails
- Async operations and error propagation

**Target:** 100% coverage of IMAPService public methods

---

### ios-cen: Add comprehensive tests for SettingsViewModel ⚡ P1

**Scope:**
- State management (isAuthenticated, error states)
- Authentication flow triggers
- Logout functionality
- Error handling and user feedback
- Async operation handling

**Coverage Goals:**
- Initial state verification
- Authentication state changes
- Error state propagation
- View updates on state changes
- @MainActor usage for UI updates

**Target:** 100% coverage of SettingsViewModel

---

### ios-def: Add integration tests for email sync workflow ⚡ P1

**Scope:**
End-to-end authentication and email sync flow:
- GmailAuthService → IMAPService → EmailMessage parsing
- Error propagation through the stack
- Retry logic and failure recovery

**Test Scenarios:**
1. Complete sync: auth → connect → fetch → disconnect
2. Auth failure → error handling → user notification
3. Network interruption during fetch → retry → recovery
4. Invalid email data → parsing error → graceful handling

**Target:** Cover all critical user journeys

---

### ios-c4l: Add edge case and error handling tests for all services ⚡ P1

**Scope:**
Comprehensive edge case coverage across all services:

**KeychainService:**
- Duplicate item handling
- Empty data storage
- Concurrent access
- Keychain access denied

**GmailAuthService:**
- Password with special characters
- Very long passwords
- Email format variations
- Network timeout during validation

**IMAPService:**
- Empty response from server
- Partial email data
- Extremely large email bodies
- Concurrent fetch requests
- Server disconnect mid-fetch

**Target:** Cover all error branches and edge cases with graceful degradation

---

### ios-x0v: Add unit tests for View logic and ViewModels 📊 P2

**Scope:**
Test business logic within Views (not UI rendering):

**ContentView:**
- Tab navigation state
- View lifecycle

**EmailListView:**
- Email filtering logic
- Sort order
- Empty state handling

**BNPLDashboardView:**
- Data aggregation logic
- Payment status calculations
- Summary statistics

**GmailAuthSetupView:**
- Form validation
- Password formatting
- Error display logic

**Target:** 80%+ coverage of View business logic

---

### ios-fsj: Add performance tests for iOS email sync and BNPL detection 📊 P2

**Scope:**
Performance benchmarking for critical operations:

**Email Sync Performance:**
- Fetch 1000 emails: measure time, memory
- IMAP connection time
- Parse email bodies: test HTML vs plain text
- Background fetch efficiency

**BNPL Detection Performance:**
- Core ML inference time per email
- Pattern matching speed
- Batch processing (100 emails)
- Memory usage during detection

**SwiftData Performance:**
- Save 1000 emails: measure time
- Query performance with indexes
- Relationship loading
- Memory footprint

**UI Performance:**
- List rendering (1000 items with lazy loading)
- Dashboard calculation time
- View state updates

**Target:** Establish baseline performance metrics

---

### ios-f9d: Add snapshot tests for UI consistency 📸 P3

**Scope:**
Snapshot testing to prevent UI regressions:

**Views to Snapshot:**
- ContentView: All tab states
- EmailListView: Empty, loading, populated, error states
- BNPLDashboardView: With 0, 1, 10+ loans
- GmailAuthSetupView: Initial, loading, error states
- SettingsView: Authenticated vs unauthenticated
- Loan detail views: Various loan states

**Test Configurations:**
- Light mode and dark mode
- Device sizes (iPhone SE, 15, 15 Pro Max)
- Dynamic type sizes (small, default, accessibility)
- Landscape and portrait orientations

**Target:** Prevent unintended UI regressions

---

## Backend Test Beads (Detailed)

### backend-hcc: Add comprehensive tests for BNPL detection service ⚡ P1

**Scope:**
Unit tests for BNPL detection logic covering all providers:

**Provider Detection:**
- **Afterpay:** 'Pay in 4' patterns, installment extraction
- **Klarna:** 'Slice it', 'Pay in 4' variations
- **Affirm:** 'Pay over time', monthly payment patterns
- **PayPal:** 'Pay in 4', 'Pay Later'
- **Shop Pay:** Installment patterns

**Pattern Matching:**
- Exact matches vs fuzzy matching
- Case insensitivity
- HTML vs plain text emails
- Multiple BNPL mentions in one email
- False positives (regular payment mentions)

**Data Extraction:**
- Total amount parsing
- Installment amount calculation
- Payment schedule extraction
- Due date parsing
- Merchant name extraction

**Target:** 90%+ coverage with extensive edge cases

---

### backend-t6i: Add comprehensive tests for email parsing service ⚡ P1

**Scope:**
Email parsing and processing tests:

**Email Format Handling:**
- HTML email parsing
- Plain text email parsing
- Multipart MIME emails
- Attachments (detect, extract metadata)
- Email encoding (UTF-8, quoted-printable, base64)

**Content Extraction:**
- Subject line parsing
- Sender email validation
- Timestamp parsing (various formats)
- Body text extraction from HTML
- Link extraction
- Remove tracking pixels/images

**Edge Cases:**
- Empty emails
- Extremely large emails (>1MB)
- Malformed HTML
- Missing headers
- Non-standard date formats
- International characters

**Target:** 85%+ coverage with focus on edge cases

---

### backend-amw: Add integration tests for all API endpoints ⚡ P1

**Scope:**
Integration tests for all FastAPI endpoints:

**Authentication Endpoints:**
- POST /auth/register - valid/invalid data, duplicate user
- POST /auth/login - correct/incorrect credentials, JWT generation
- POST /auth/refresh - token refresh, expired tokens
- GET /auth/me - authenticated user info

**Email Endpoints:**
- GET /emails - pagination, filtering, sorting
- POST /emails/sync - trigger sync, auth required
- GET /emails/{id} - valid/invalid ID, permissions

**BNPL Loan Endpoints:**
- GET /loans - list user loans, filtering by status/date
- GET /loans/{id} - loan details
- POST /loans/{id}/pay - mark payment, validate dates
- GET /loans/summary - aggregate stats

**Health/Utility:**
- GET /health - system health check
- GET /docs - OpenAPI documentation

**Test All Endpoints With:**
- Valid authentication headers
- Missing/invalid auth
- Various input combinations
- Error responses (400, 401, 404, 422, 500)
- Rate limiting (if implemented)

**Target:** 100% endpoint coverage

---

### backend-oxn: Add comprehensive tests for database models and operations ⚡ P1

**Scope:**
Database layer tests:

**SQLAlchemy Models:**
- User model: creation, validation, password hashing
- Email model: relationships, timestamps, indexing
- BNPLLoan model: calculations, status updates
- Transaction model: payment tracking

**CRUD Operations:**
- Create: valid data, constraint violations, duplicates
- Read: queries, filters, joins, pagination
- Update: partial updates, optimistic locking
- Delete: cascade behavior, soft deletes

**Model Relationships:**
- User → Emails (one-to-many)
- User → BNPLLoans (one-to-many)
- BNPLLoan → Transactions (one-to-many)
- Email → BNPLLoan (extraction relationship)

**Database Constraints:**
- Unique constraints (user email, etc.)
- Foreign key constraints
- Not null constraints
- Check constraints (positive amounts, valid dates)

**Alembic Migrations:**
- Test migration up/down
- Schema validation
- Data migration correctness

**Target:** 90%+ coverage of database layer

---

### backend-0c8: Add comprehensive tests for authentication and JWT handling ⚡ P1

**Scope:**
Authentication system tests:

**Password Security:**
- Password hashing (bcrypt/argon2)
- Hash verification
- Salt generation
- Timing attack resistance

**JWT Token Management:**
- Token generation with correct claims
- Token expiration handling
- Token refresh mechanism
- Invalid token detection
- Revoked token handling (if implemented)

**Authentication Flow:**
- User registration → password hash → JWT
- Login → verify password → JWT
- Protected endpoint → verify JWT → user context
- Token refresh → new JWT
- Logout → token invalidation

**Pydantic Schema Validation:**
- UserCreate: email validation, password strength
- UserLogin: required fields
- Token response: correct structure
- User response: no password leak

**Security Tests:**
- SQL injection attempts
- XSS in user inputs
- Password in logs/errors
- JWT secret exposure
- CORS configuration

**Target:** 95%+ coverage - security critical

---

### backend-vxi: Add comprehensive tests for Gmail API integration ⚡ P1

**Scope:**
Gmail API integration service tests:

**OAuth 2.0 Flow:**
- Authorization URL generation
- Token exchange
- Token refresh
- Credential storage/retrieval
- OAuth error handling

**Gmail API Operations:**
- List messages with query filters
- Get message by ID
- Parse message payload
- Handle pagination (nextPageToken)
- Rate limiting and backoff

**API Response Handling:**
- Success responses → data extraction
- 4xx errors → user-friendly messages
- 5xx errors → retry logic
- Network errors → exponential backoff
- Quota exceeded → graceful degradation

**Security:**
- Credential encryption at rest
- No credentials in logs
- Secure token storage
- Revocation handling

**Integration with Email Sync:**
- Fetch → Parse → Detect BNPL → Store
- Incremental sync (since last fetch)
- Handle duplicates

**Target:** 85%+ coverage

---

### backend-cq0: Add end-to-end tests for complete user workflows 📊 P2

**Scope:**
End-to-end integration tests for full user journeys:

**Journey 1: New User Onboarding**
- Register account → verify JWT
- Connect Gmail → OAuth flow
- First email sync → BNPL detection
- View dashboard → see results

**Journey 2: Daily Email Sync**
- Login → JWT valid
- Trigger sync → fetch new emails
- Detect new BNPL loans
- View loan details
- Mark payment as paid

**Journey 3: Error Recovery**
- Login with wrong password → error
- Retry with correct password → success
- Gmail auth expired → re-auth
- Network error during sync → retry → success

**Journey 4: Data Management**
- View all loans
- Filter by provider/status
- View payment schedule
- Check loan summary/stats

**Test Configuration:**
- Use TestClient for API
- In-memory database
- Mock Gmail API
- Test across multiple users
- Verify data isolation

**Target:** Cover top 5 user journeys

---

### backend-osc: Add performance and load tests for critical paths 📊 P2

**Scope:**
Performance and load testing:

**API Performance Tests:**
- Login endpoint: 100 req/sec
- Email list endpoint: 50 req/sec with pagination
- BNPL detection: process 1000 emails in <30s
- Dashboard summary: calculate stats for 100 loans in <1s

**Database Performance:**
- Query optimization verification
- Index effectiveness
- Join performance
- Pagination efficiency (offset vs cursor)

**Gmail API Performance:**
- Batch processing efficiency
- Rate limit compliance
- Concurrent fetch operations
- Memory usage for large emails

**Load Tests (using locust or pytest-benchmark):**
- Concurrent user simulation (10, 50, 100 users)
- Database connection pool sizing
- Memory leak detection
- Response time percentiles (p50, p95, p99)

**Performance Benchmarks:**
- Email sync: 1000 emails in <2 minutes
- BNPL detection: 100 emails/second
- API response time: p95 < 200ms
- Database queries: p99 < 50ms

**Target:** Establish performance baselines

---

## Execution Strategy

### Phase 1: Core Service Tests (P1) - Immediate
These should be implemented alongside or immediately after core features:

**iOS:**
- ios-5at (IMAPService)
- ios-cen (SettingsViewModel)
- ios-def (Email sync integration)
- ios-c4l (Edge cases)

**Backend:**
- backend-hcc (BNPL detection)
- backend-t6i (Email parsing)
- backend-amw (API endpoints)
- backend-oxn (Database)
- backend-0c8 (Authentication)
- backend-vxi (Gmail API)

### Phase 2: Integration & Performance (P2) - After Core Features
Once core features are implemented and tested:

**iOS:**
- ios-x0v (View logic)
- ios-fsj (Performance)

**Backend:**
- backend-cq0 (E2E workflows)
- backend-osc (Performance)

### Phase 3: UI Quality (P3) - Continuous
Ongoing throughout development:

**iOS:**
- ios-f9d (Snapshot tests)

## Success Metrics

### Coverage Goals
- **Backend:** 70% minimum (enforced), target 85%+
- **iOS:** Target 80%+ for business logic

### Test Distribution
- **Unit tests:** 60-70% of all tests
- **Integration tests:** 20-30% of all tests
- **E2E tests:** 5-10% of all tests
- **Performance tests:** Establish baselines, run periodically

### Quality Gates
- All P1 tests must pass before merging
- Coverage must not decrease
- Performance benchmarks must not regress by >10%

## Orchestrator Integration

All test beads will be executed by the autonomous orchestrator:

1. Agent picks up test bead
2. Reads existing code to understand implementation
3. Writes comprehensive tests following patterns
4. Runs tests locally (`make test`)
5. Ensures 70%+ coverage
6. Commits and creates PR
7. Checker validates test quality
8. Reviewer ensures comprehensive coverage

## Notes

- Tests should follow existing patterns (see GmailAuthServiceTests, KeychainServiceTests)
- Use fixtures from conftest.py (backend) and MockData.swift (iOS)
- Mock external dependencies (Gmail API, IMAP, Keychain)
- Test both happy paths and error paths
- Include edge cases (null, empty, malformed data)
- Performance tests marked with `@pytest.mark.slow` or similar
- All tests must be deterministic and fast (<5s per test file)

---

**Status:** ✅ 15 test beads created and ready for autonomous execution
**Next Step:** Orchestrators will pick up and execute tests as dependencies are satisfied
