# Governance of the Astra Programming Language

## Overview

Astra is governed by a **modified BDFL (Benevolent Dictator For Life)** model with a Core Team during the pre-1.0 phase. This document describes how decisions are made and how the project is organized.

## Current Phase: Pre-1.0

### Leadership Structure

| Role | Responsibility |
|:-----|:---------------|
| **BDFL (Founder)** | Final decision authority, sets project vision, delegates extensively |
| **Core Team** | Reviews proposals, implements features, mentors contributors |
| **Contributors** | Submit code, documentation, and proposals |

### Decision-Making Process

1. **Discussion**: Proposals are discussed in GitHub Discussions or Issues
2. **Review**: Core team reviews proposals (~2 weeks)
3. **Decision**: BDFL or delegated core team member makes final decision
4. **Implementation**: Accepted proposals are implemented via PRs

### Core Team

The Core Team consists of 3-5 members selected from early contributors. Core team members:

- Have merge rights to the repository
- Review and approve pull requests
- Participate in design discussions
- Represent different areas of expertise (compiler, runtime, tooling, community)

## RFC Process (Lightweight)

### Lifecycle

```
1. Discussion  → 2. Proposal  → 3. Review  → 4. Decision  → 5. Implementation  → 6. Stabilization
```

### Proposal Template

```markdown
# Proposal: [Title]

## Summary
One paragraph description of the proposal.

## Motivation
Why this change is needed. What problem does it solve?

## Detailed Design
Technical details of the proposed change.

## Examples
Code examples showing how the feature would be used.

## Alternatives Considered
Other approaches that were considered and why they were rejected.

## Impact
How this change affects existing code and the ecosystem.
```

### Proposal Statuses

| Status | Description |
|:-------|:------------|
| **Draft** | Initial proposal, open for discussion |
| **Accepted** | Approved by core team, ready for implementation |
| **Rejected** | Not accepted, with documented rationale |
| **Deferred** | Postponed to a future version |
| **Implemented** | Merged into the language |
| **Stabilized** | No longer behind a feature flag |

## Feature Lifecycle

```
Idea → Discussion → Proposal → Core Team Review → Accept/Reject
→ Implementation (nightly/unstable) → Testing → Stabilization
```

### Feature Flags

During development, new features are behind unstable flags:

```astra
#![feature(my_new_feature)]

// Feature code here
```

Features become stable after:
- At least one release cycle on nightly
- Positive community feedback
- Adequate test coverage
- Documentation complete

## Backwards Compatibility

Astra uses an **Edition System** (like Rust):

- Each crate specifies its edition in `astra.toml`
- Editions are opt-in
- Crates from different editions interoperate seamlessly
- `astra fix` automates migration between editions
- Breaking changes are only allowed in new editions

## Future: 1.0 Foundation

At the 1.0 release, governance will transition to:

### Astra Foundation

- **Legal structure**: 501(c)(3) nonprofit
- **Board composition**: 3 Project Directors + 2-3 Corporate Members + 1-2 Community Directors + 1 Independent
- **Responsibilities**: Trademarks, infrastructure, conferences, legal, funding
- **Does NOT own**: Technical decisions, language design

### Leadership Council

- Representatives from all top-level teams
- Consent-based decision-making
- Delegates authority to specialized teams

## Release Process

| Channel | Frequency | Content |
|:--------|:----------|:--------|
| Nightly | Every night | All features, unstable |
| Beta | Every 2 months | Branch from nightly |
| Stable | Every 2 months | Branch from beta |

## Trademark Policy

- The name "Astra" and logo are trademarks of the Astra project
- Non-commercial use is allowed without permission
- Commercial use requires written permission
- Modified distributions cannot be called "Astra" without permission

## Communication

- **GitHub Discussions**: Design discussions, questions
- **GitHub Issues**: Bug reports, feature requests
- **Core Team Meetings**: Monthly (minutes published)

## Changes to Governance

Changes to this governance document require:
- Approval by BDFL or 2/3 majority of Core Team
- Public comment period of 2 weeks
- No objections from active contributors

---

*This governance model will evolve as the project matures.*
