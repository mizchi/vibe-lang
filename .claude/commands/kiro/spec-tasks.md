---
description: Generate implementation tasks for a specification
allowed-tools: Bash, Read, Write, Edit, Update, MultiEdit
---

# Implementation Tasks

Generate detailed implementation tasks for feature: **$ARGUMENTS**

## Approval Gate: Requirements & Design Check

**CRITICAL**: Tasks can only be generated after both requirements and design are approved.

### Approval Status Check
- Spec metadata: @.kiro/specs/$ARGUMENTS/spec.json

**STOP HERE** if spec.json shows:
```json
"approvals": {
  "requirements": {
    "approved": false  // Must be true
  },
  "design": {
    "approved": false  // Must be true
  }
}
```

**Required Actions for Full Approval**:

### If Requirements Not Approved:
1. **Review requirements.md** - Read through the generated requirements thoroughly
2. **Edit if needed** - Make any necessary changes directly in the requirements.md file
3. **Manual approval required** - Update spec.json to set `"requirements": {"approved": true}`

### If Design Not Approved:
1. **Review design.md** - Read through the generated design thoroughly
2. **Edit if needed** - Make any necessary changes directly in the design.md file
3. **Manual approval required** - Update spec.json to set `"design": {"approved": true}`
4. **Reasoning**: Human review ensures technical design accuracy before task breakdown

**Example full approval in spec.json**:
```json
{
  "approvals": {
    "requirements": {
      "generated": true,
      "approved": true  // ← Human reviewed and approved
    },
    "design": {
      "generated": true,
      "approved": true  // ← Human reviewed and approved
    }
  },
  "phase": "design-approved"
}
```

**Only proceed to task generation after both requirements and design are explicitly approved by human review.**

## Context Analysis

### Complete Spec Context (APPROVED)
- Requirements: @.kiro/specs/$ARGUMENTS/requirements.md
- Design: @.kiro/specs/$ARGUMENTS/design.md
- Current tasks: @.kiro/specs/$ARGUMENTS/tasks.md
- Spec metadata: @.kiro/specs/$ARGUMENTS/spec.json

### Steering Context
- Architecture patterns: @.kiro/steering/structure.md
- Development practices: @.kiro/steering/tech.md
- Product constraints: @.kiro/steering/product.md

## Task: Generate Implementation Plan

**Prerequisites Verified**: Both requirements and design are approved and ready for task breakdown.

Create comprehensive implementation plan in the language specified in spec.json:

### 1. Tasks Document Structure
Create tasks.md in the language specified in spec.json (check `@.kiro/specs/$ARGUMENTS/spec.json` for "language" field):

```markdown
# Implementation Plan

- [ ] 1. Project Setup and Core Structure
  - Create frontend (React/Vue/Next.js) and backend (FastAPI/Express) directory structure
  - Define TypeScript types and core data model interfaces
  - Set up development environment files (package.json, requirements.txt, docker-compose.yml)
  - _Requirements: 1.1, 1.2_

- [ ] 2. Database and Model Layer Implementation
- [ ] 2.1 Database Schema Design and Implementation
  - Define schemas using [ORM/Database] (Prisma/SQLAlchemy/Mongoose)
  - Create and run migration files
  - Implement database connection utilities
  - _Requirements: 2.1, 2.2_

- [ ] 2.2 Data Validation and Business Logic
  - Implement model validation functions
  - Implement and test business rules
  - Standardize error handling across models
  - _Requirements: 2.3_

- [ ] 3. API and Backend Services Implementation
- [ ] 3.1 Authentication and Authorization System
  - Implement JWT/session authentication with [Auth Library]
  - Create user registration and login endpoints
  - Implement access control middleware and route protection
  - _Requirements: 3.1, 3.2_

- [ ] 3.2 Core API Endpoints Implementation
  - Implement CRUD operations for main entities
  - Add input validation and sanitization
  - Create API documentation with OpenAPI/Swagger
  - _Requirements: 3.3, 3.4_

- [ ] 4. Frontend Component Implementation
- [ ] 4.1 Basic UI Component Creation
  - Select and configure component library ([Chakra UI/Material-UI/Tailwind])
  - Implement common components (Button, Input, Modal, Table)
  - Set up responsive design system and theme
  - _Requirements: 4.1, 4.2_

- [ ] 4.2 Feature-Specific Components
  - Implement main feature components based on requirements
  - Add form handling with validation ([Formik/React Hook Form])
  - Implement state management ([Redux/Zustand/Context])
  - _Requirements: 4.3, 4.4_

- [ ] 5. Integration and Testing
- [ ] 5.1 Test Suite Implementation
  - Create unit tests for backend services (Jest/pytest)
  - Implement API integration tests
  - Set up frontend component tests ([Testing Library])
  - _Requirements: All requirements test coverage_

- [ ] 5.2 End-to-End Testing and Deployment
  - Implement E2E tests ([Playwright/Cypress])
  - Set up CI/CD pipeline configuration
  - Configure production deployment and monitoring
  - _Requirements: 5.1, 5.2_
```

**Key Format Rules**:
- Hierarchical numbering: Major phases (1, 2, 3) and sub-tasks (1.1, 1.2)
- Each task contains 2-4 concrete, actionable items
- Specify technologies in brackets: [React], [FastAPI], [Prisma]
- End with requirement mapping: _Requirements: X.X, Y.Y_
- Tasks should be completable in 2-4 hours each
- Include testing tasks for each major component

### 2. Task Quality Guidelines
- **Hierarchical Structure**: Group related tasks into phases
- **Discrete Tasks**: Each task should be completable in 2-4 hours
- **Clear Acceptance Criteria**: Define what "done" means
- **Requirements Mapping**: Link tasks to specific requirements
- **Dependency Management**: Order tasks by dependencies
- **Testable Outcomes**: Each task should have verifiable results

### 3. Task Categories
Include tasks for:
- **Data Models**: Database schema and model creation
- **API Endpoints**: Backend service implementation
- **UI Components**: Frontend component development
- **Integration**: Service integration and workflow
- **Testing**: Unit, integration, and E2E tests
- **Documentation**: Code documentation and user guides

### 4. Requirements Mapping
For each task, reference the specific requirements from requirements.md:
- Map to user stories (要件1, 要件2, etc.)
- Include acceptance criteria references
- Ensure full requirements coverage

### 5. Progress Tracking
Include progress tracking section:
```markdown
## 進捗状況
- Created: [timestamp]
- Status: Ready for implementation
- Total tasks: [count]
- Completed: 0
- Remaining: [count]
```

### 6. Document Generation Only
Generate the tasks document content ONLY. Do not include any review or approval instructions in the actual document file.

### 7. Update Metadata

Update spec.json with:
```json
{
  "phase": "tasks-generated",
  "progress": {
    "requirements": 100,
    "design": 100, 
    "tasks": 100
  },
  "approvals": {
    "requirements": {
      "generated": true,
      "approved": true
    },
    "design": {
      "generated": true,
      "approved": true
    },
    "tasks": {
      "generated": true,
      "approved": false
    }
  },
  "updated_at": "current_timestamp"
}
```

### 8. Metadata Update
Update the tracking metadata to reflect task generation completion.

---

## REVIEW AND APPROVAL PROCESS (Not included in document)

The following is for Claude Code conversation only - NOT for the generated document:

### Human Review Required
After generating tasks.md, inform the user:

**NEXT STEP**: Human review required before starting implementation.

### Review Checklist:
- [ ] Tasks are properly sized (2-4 hours each)
- [ ] All requirements are covered by tasks
- [ ] Task dependencies are correct
- [ ] Technology choices match the design
- [ ] Testing tasks are included

### To Approve:
After reviewing, update `.kiro/specs/$ARGUMENTS/spec.json`:
```json
{
  "approvals": {
    "requirements": {
      "generated": true,
      "approved": true
    },
    "design": {
      "generated": true,
      "approved": true
    },
    "tasks": {
      "generated": true,
      "approved": true
    }
  },
  "phase": "ready-for-implementation",
  "ready_for_implementation": true
}
```

**Only after approval can you start implementation.**

## Instructions

1. **Check spec.json for language** - Use the language specified in the metadata
2. **Analyze requirements and design** to understand full scope
3. **Create hierarchical task structure** with clear phases
4. **Define discrete, actionable tasks** with acceptance criteria
5. **Map all tasks to requirements** to ensure coverage
6. **Order tasks by dependencies** for logical implementation flow
7. **Include testing and documentation** tasks
8. **Update tracking metadata** upon completion

Generate tasks that provide clear roadmap for implementation.
ultrathink