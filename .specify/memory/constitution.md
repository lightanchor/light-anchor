<!--
Sync Impact Report
- Version: template → 1.0.0 (initial constitution with two requested rules)
- Modified principles: none (initial adoption)
- Added sections: Major-change packaging; Current-design decisions
- Removed sections: template placeholders
- Follow-up TODOs: none
-->

# Light Anchor Constitution

## Core Principles

### I. Major Changes Ship as Packages

When a change is classified as a major software change, the implementation MUST be
packaged immediately after the change is complete. The delivery record MUST identify the
new package artifacts and the verification result. A previous package MUST NOT be
presented as the result of the current change.

### II. Current Design Decides Before Release

Before a release, new design decisions MUST be made from the current product goals,
requirements, and constraints. Historical implementation choices MUST NOT constrain a new
design. The project MUST NOT retain historical code, data shapes, compatibility layers,
migration branches, dual implementations, or fallback mappings solely to preserve an old
design; if a decision would materially affect scope, it requires an explicit current
requirement.

## Major-Change Classification

A change is major when it changes the software's primary structure, navigation, central
user interaction, or overall visual direction. The feature specification MUST state
whether the change is major before implementation begins.

## Development Workflow

1. Record the current requirement and acceptance criteria in a feature specification.
2. Mark the change as major or non-major before implementation.
3. Implement and verify the change.
4. For a major change, package it immediately and record the package paths and checks.
5. Before release, review design decisions against current requirements and confirm that
   no historical compatibility work remains solely for its own sake.

## Governance

This constitution records the two project rules explicitly requested by the project owner.
Future rules or amendments MUST be proposed as a reviewed change to this file. An
amendment MUST update the semantic version, amendment date, and sync impact report.

**Version**: 1.0.0 | **Ratified**: 2026-09-13 | **Last Amended**: 2026-09-13
