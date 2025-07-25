---
description: Generate comprehensive requirements for a specification
allowed-tools: Bash, Read, Write, Edit, MultiEdit, Update, WebSearch, WebFetch
---

# Requirements Generation

Generate comprehensive requirements for feature: **$ARGUMENTS**

## Context Validation

### Steering Context
- Architecture context: @.kiro/steering/structure.md
- Technical constraints: @.kiro/steering/tech.md
- Product context: @.kiro/steering/product.md

### Existing Spec Context
- Current spec directory: !`ls -la .kiro/specs/$ARGUMENTS/`
- Current requirements: @.kiro/specs/$ARGUMENTS/requirements.md
- Spec metadata: @.kiro/specs/$ARGUMENTS/spec.json

## Task: Generate Detailed Requirements

Create comprehensive requirements document in the language specified in spec.json:

### 1. Requirements Structure
Generate requirements.md in the language specified in spec.json (check `@.kiro/specs/$ARGUMENTS/spec.json` for "language" field):

```markdown
# Requirements Specification

## Overview
[Clear overview of the feature and its purpose]

## Requirements

### Requirement 1
**User Story:** As a [user type], I want to [do something], so that I can [achieve some goal]

#### Acceptance Criteria
1. WHEN [specific condition] THEN [specific expected outcome]
2. WHEN [specific condition] THEN [specific expected outcome]
3. IF [exception condition] THEN [expected error handling]

### Requirement 2
**User Story:** As a [user type], I want to [do something], so that I can [achieve some goal]

#### Acceptance Criteria
1. WHEN [specific condition] THEN [specific expected outcome]
2. WHEN [specific condition] THEN [specific expected outcome]
3. IF [exception condition] THEN [expected error handling]

### Requirement 3
[Additional requirements following same pattern]
```

### 2. Requirements Quality Guidelines
- **User-Centric**: Write from user perspective
- **Testable**: Each acceptance criterion should be verifiable
- **Specific**: Use concrete conditions and outcomes
- **Complete**: Cover all major user scenarios
- **Contextual**: Consider existing system integration

### 3. Integration Considerations
Based on steering context, consider:
- How this feature fits with existing architecture
- Technical constraints that affect requirements
- Existing user workflows that need integration
- Performance and scalability requirements

### 4. Update Metadata
Update spec.json with:
```json
{
  "phase": "requirements-generated",
  "progress": {
    "requirements": 100,
    "design": 0,
    "tasks": 0
  },
  "approvals": {
    "requirements": {
      "generated": true,
      "approved": false
    }
  },
  "updated_at": "current_timestamp"
}
```

### 5. Document Generation Only
Generate the requirements document content ONLY. Do not include any review or approval instructions in the actual document file.

---

## REVIEW AND APPROVAL PROCESS (Not included in document)

The following is for Claude Code conversation only - NOT for the generated document:

### Human Review Required
After generating requirements.md, inform the user:

**NEXT STEP**: Human review required before proceeding to design phase.

### Review Checklist:
- [ ] Requirements are clear and complete
- [ ] User stories cover all necessary functionality
- [ ] Acceptance criteria are testable
- [ ] Requirements align with project goals

### To Approve:
After reviewing, update `.kiro/specs/$ARGUMENTS/spec.json`:
```json
{
  "approvals": {
    "requirements": {
      "generated": true,
      "approved": true
    }
  },
  "phase": "requirements-approved"
}
```

**Only after approval can you proceed to `/spec-design $ARGUMENTS`**

## Instructions

1. **Check spec.json for language** - Use the language specified in the metadata
2. **Analyze existing product context** to understand user needs
3. **Create user-focused requirements** with clear acceptance criteria
4. **Consider technical constraints** from steering documents
5. **Ensure requirements are testable** and specific
6. **Update tracking metadata** upon completion

Generate requirements that provide clear foundation for design phase.
ultrathink