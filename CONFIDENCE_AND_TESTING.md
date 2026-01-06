# Confidence and Testing Framework

This document describes the orchestrator's confidence mechanism and testing requirements for autonomous development.

## Overview

The orchestrator uses a multi-stage validation and confidence system to ensure code quality before merging:

1. **Implementer Agent** (opus-4.5-thinking) - Implements the task
2. **Checker Agent** (haiku-4.5) - Evaluates completeness and confidence
3. **Validation Pipeline** - Runs lint, typecheck, and tests
4. **Reviewer Agent** (sonnet-4) - Fresh-eyes code review

## Confidence Mechanism

### How It Works

After the implementer completes changes, the checker agent evaluates the work and returns:

```json
{
  "complete": boolean,         // Is the task fully implemented?
  "confidence": number,         // 0.0 to 1.0 confidence score
  "visual_verified": boolean,   // UI changes verified?
  "blocking_gaps": [...],       // Issues that must be fixed
  "suggested_edits": [...]      // Non-blocking improvements
}
```

### Acceptance Criteria

For a change to proceed, it must meet **BOTH** criteria:

- `complete = true` - Task is fully implemented
- `confidence >= 0.70` - Confidence threshold (default: 70%)

### Configuration

```bash
ENABLE_CHECKER=1                      # Enable/disable checker
CHECKER_MODEL="haiku-4.5"             # Model for checking
CHECKER_CONF_THRESHOLD=0.70           # Minimum confidence (70%)
MAX_REPAIR_ATTEMPTS=1                 # Repair attempts if check fails
```

### What Influences Confidence?

The checker evaluates:

1. **Task Completion** - All acceptance criteria met
2. **Code Quality** - Follows project patterns
3. **Error Handling** - Adequate error coverage
4. **Edge Cases** - Null/empty/undefined handled
5. **Security** - No obvious vulnerabilities
6. **Tests** - Appropriate test coverage (NEW as of 2026-01-05)

## Testing Requirements

### Backend (Python)

**Minimum Requirements:**
- ✅ Tests must pass (`pytest`)
- ✅ Minimum 70% code coverage
- ✅ Type checking must pass (`mypy`)
- ✅ Code formatted (`black`, `isort`)

**Test Structure:**
```
backend/
├── tests/
│   ├── conftest.py              # Shared fixtures
│   ├── unit/                    # Fast, isolated tests
│   │   ├── test_bnpl_detection.py
│   │   └── test_email_parser.py
│   └── integration/             # End-to-end tests
│       ├── test_api_endpoints.py
│       └── test_auth.py
├── pytest.ini                   # Pytest configuration
└── Makefile                     # Validation targets
```

**Running Tests:**
```bash
make test          # Run all tests with coverage
make test-unit     # Unit tests only
make validate      # Full validation (typecheck + tests)
```

**Validation Command:**
```bash
export VALIDATE_CMD="make validate 2>&1 || echo 'No Makefile yet'"
```

### iOS (Swift)

**Minimum Requirements:**
- ✅ Tests must pass (`swift test`)
- ✅ Build must succeed (`swift build`)
- ✅ Code formatted (optional: `swift-format`)

**Test Structure:**
```
ios/
├── FinancialAdvisor/
│   ├── Sources/
│   │   └── [implementation code]
│   └── Tests/
│       ├── Helpers/
│       │   └── MockData.swift
│       └── Services/
│           ├── GmailAuthServiceTests.swift
│           └── KeychainServiceTests.swift
├── Package.swift                # Swift Package Manager
└── Makefile                     # Validation targets
```

**Running Tests:**
```bash
make test          # Run all tests
make test-cov      # Run with coverage
make validate      # Full validation (build + test)
```

**Validation Command:**
```bash
export VALIDATE_CMD="make validate 2>&1 || echo 'No Makefile yet'"
```

## Validation Pipeline

The orchestrator runs a multi-stage validation pipeline:

### Stage 1: Lint (Fast, Auto-fixable)

**Purpose:** Code style and formatting

**Backend:**
- `black` - Code formatting (line length: 88)
- `isort` - Import sorting
- `flake8` - Linting

**iOS:**
- `swift-format` - Code formatting (optional)

**Auto-fix:** ✅ Enabled by default

### Stage 2: Typecheck (Medium Speed)

**Purpose:** Static type analysis

**Backend:**
- `mypy` - Python type checking
- Checks: `src/` directory
- Config: `pyproject.toml`

**iOS:**
- Swift has built-in type checking during build

**Auto-fix:** ❌ Requires agent intervention

### Stage 3: Test (Slower, Critical)

**Purpose:** Verify functionality and coverage

**Backend:**
- `pytest` with coverage plugin
- Minimum 70% coverage required
- Fails if coverage below threshold

**iOS:**
- `swift test` with XCTest framework
- Coverage tracking available via `--enable-code-coverage`

**Auto-fix:** ❌ Requires agent intervention

### Stage 4: Review (Optional, Slow)

**Purpose:** Fresh-eyes code review by different model

**Configuration:**
```bash
ENABLE_REVIEWER=1                     # Enable/disable reviewer
REVIEWER_MODEL="sonnet-4"             # Different model for fresh perspective
REVIEW_DEPTH="standard"               # minimal|standard|thorough
REVIEWER_CAN_FIX=1                    # Allow fixes based on review
MAX_REVIEW_FIX_ATTEMPTS=2             # Maximum fix iterations
MIN_LINES_FOR_REVIEW=5                # Skip review for tiny changes
```

## Confidence Improvements (2026-01-05)

### Changes Made

1. **Added Testing Infrastructure**
   - Backend: pytest with coverage, conftest.py, example tests
   - iOS: Verified existing XCTest infrastructure

2. **Updated Validation Commands**
   - Backend: `make typecheck` → `make validate` (typecheck + tests)
   - iOS: `xcodebuild build` → `make validate` (build + tests)

3. **Created Makefiles**
   - Backend: `make test`, `make typecheck`, `make fmt`, `make validate`
   - iOS: `make test`, `make build`, `make fmt`, `make validate`

4. **Set Coverage Requirements**
   - Backend: Minimum 70% coverage enforced by pytest
   - iOS: Coverage available but not enforced yet

### Impact on Confidence

**Before:**
- Validation only checked typecheck (backend) or build (iOS)
- No test execution during validation
- Checker had limited signal about code quality
- Confidence based mainly on code review, not execution

**After:**
- Validation runs full test suite
- Coverage metrics available to checker
- Failing tests block acceptance
- Higher confidence from proven functionality

### Confidence Calculation (Recommended Enhancement)

The checker prompt could be enhanced to include test results:

```
TASK: [task description]

CHANGES:
[git diff]

TEST RESULTS:
- Tests run: 24
- Tests passed: 24
- Coverage: 85%

REVIEW CHECKLIST:
1. Do all tests pass? ✓
2. Is coverage above 70%? ✓
3. Are edge cases tested?
4. Is error handling tested?
5. Does code follow patterns?
...
```

## Best Practices

### For Agent Implementations

1. **Always Write Tests**
   - Every implementation must include tests
   - Test edge cases, error conditions
   - Mock external dependencies

2. **Aim for High Coverage**
   - Target 80%+ coverage (minimum 70%)
   - Focus on business logic
   - Don't test framework code

3. **Follow Test Patterns**
   - Backend: Use fixtures from `conftest.py`
   - iOS: Use mocks from `Tests/Helpers/`
   - Write descriptive test names

4. **Run Locally Before Commit**
   ```bash
   # Backend
   make fmt && make validate

   # iOS
   make fmt && make validate
   ```

### For Orchestrator Configuration

1. **Set Realistic Thresholds**
   - Start with 70% coverage, increase gradually
   - Adjust confidence threshold based on results
   - Monitor false positives/negatives

2. **Enable All Stages**
   ```bash
   ENABLE_CHECKER=1
   ENABLE_REVIEWER=1
   VALIDATION_STAGES="lint typecheck test"
   ```

3. **Use Appropriate Models**
   - Implementer: `opus-4.5-thinking` (deep reasoning)
   - Checker: `haiku-4.5` (fast, consistent)
   - Reviewer: `sonnet-4` (balanced, fresh perspective)

4. **Monitor and Tune**
   - Check logs: `~/.local/log/financial-advisor-*.log`
   - Review blocked tasks: `bd list --status blocked`
   - Adjust thresholds based on patterns

## Troubleshooting

### "Tests not found" Error

**Backend:**
```bash
# Ensure tests directory exists
ls -la tests/

# Verify pytest can discover tests
uv run pytest --collect-only
```

**iOS:**
```bash
# Ensure test target exists
swift package describe

# List test targets
swift test --list-tests
```

### "Coverage below threshold" Error

**Backend:**
```bash
# Generate coverage report
make test-cov

# Open HTML report
open htmlcov/index.html

# Identify uncovered lines, add tests
```

**iOS:**
```bash
# Generate coverage
make test-cov

# View coverage in Xcode or via xcresult bundle
```

### Checker Confidence Too Low

**Common causes:**
- Missing tests for new functionality
- Incomplete error handling
- TODO comments in implementation
- Missing edge case handling

**Solutions:**
1. Add comprehensive tests
2. Handle all error conditions
3. Remove TODO comments or implement them
4. Test edge cases (null, empty, invalid input)

### Validation Timeout

**Symptoms:** Tests hang or timeout

**Solutions:**
1. Check for infinite loops
2. Mock slow external services
3. Increase timeout: `TEST_TIMEOUT_SECS=600`
4. Use `@pytest.mark.slow` for long tests

## Future Enhancements

### Recommended Improvements

1. **Dynamic Confidence Threshold**
   - Adjust threshold based on task complexity
   - Higher threshold for critical changes
   - Lower for documentation/formatting

2. **Test Quality Metrics**
   - Measure assertion count
   - Detect trivial tests (`assert True`)
   - Require meaningful test names

3. **Coverage-Based Confidence**
   - Include coverage % in confidence calculation
   - Bonus for >80% coverage
   - Penalty for <70% coverage

4. **Integration Test Signals**
   - Weight integration tests higher
   - Require end-to-end tests for API changes
   - Validate database migrations

5. **Performance Testing**
   - Benchmark critical paths
   - Fail if performance regresses
   - Track query counts, response times

6. **Security Scanning**
   - Add `bandit` (Python) or `SwiftLint` security rules
   - Scan for hardcoded secrets
   - Check dependency vulnerabilities

## Summary

The confidence and testing framework ensures:

- ✅ All code is tested before merge
- ✅ Minimum quality bar enforced automatically
- ✅ Agent implementations are reliable
- ✅ Regressions caught early
- ✅ High confidence in autonomous changes

**Key Metrics:**
- Confidence threshold: **70%**
- Coverage requirement: **70%**
- Validation stages: **lint → typecheck → test → review**

**Result:** Autonomous development with high reliability and minimal manual intervention.
