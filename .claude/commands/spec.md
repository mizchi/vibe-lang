# Lightweight Task Workflow Command

## Command: /spec [feature-name]

Creates a lightweight task workflow without approval phases for quick feature implementation.

### Description

The `/spec` command provides a streamlined alternative to the full spec-driven process. It analyzes your feature name, generates smart task breakdowns, and starts implementation immediately without requiring approval phases.

### Usage

```
/task [feature-name]
```

### Features

- **Immediate start**: No approval phases - implementation begins right away
- **Smart planning**: Analyzes feature type and generates appropriate task breakdown
- **Simple structure**: Tasks saved to `.claude/specs/YYYYMMDD-feature-name-tasks.md`
- **User control**: Review and modify tasks during implementation
- **TodoWrite integration**: Automatic tracking of active work items
- **Date-prefixed**: Files automatically named with today's date

### Smart Task Analysis

The command intelligently analyzes your feature name to determine:

- **Feature type**: bugfix, refactor, testing, optimization, or feature
- **Complexity**: simple, medium, or complex
- **Task structure**: Type-specific task breakdowns and completion criteria

### Feature Type Detection

- Contains "fix" or "bug" → Bugfix workflow (reproduce, debug, fix, test)
- Contains "refactor" → Refactoring workflow (analyze, plan, implement, validate)
- Contains "test" → Testing workflow (identify gaps, design cases, implement, verify)
- Contains "optimize" or "performance" → Optimization workflow (profile, analyze, optimize, measure)
- Contains "add", "implement", or "create" → Feature workflow (design, implement, test, document)

### When to Use

**Use `/task` for:**

- Small features
- Bug fixes
- Refactoring tasks
- Experiments
- Time-sensitive work

**Use full spec workflow for:**

- Major features
- Architectural changes
- Complex systems requiring formal approval

### Implementation

When you run `/task [feature-name]`, Claude will:

1. Create a task file in `.claude/specs/` with YYYYMMDD prefix
2. Analyze the feature type from the name
3. Generate appropriate task breakdown based on the type
4. Include completion criteria and implementation guidelines
5. Start implementation immediately
6. Use TodoWrite to track active work items

### Example

```
/task fix user login validation bug
```

This would create `.claude/specs/20250125-fix-user-login-validation-bug-tasks.md` with:

- Bugfix-specific task structure
- Steps to reproduce, debug, fix, and test
- Regression test requirements
- Immediate start on reproduction task
