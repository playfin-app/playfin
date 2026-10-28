# ADR 0001: App License Selection (MPL-2.0)

## Context
We need a permissive yet protective open-source license that:
1. Allows anyone to use, modify, and redistribute the application.
2. Ensures modifications to the client's own code remain open source (file-level copyleft).
3. Easily links with LGPL-licensed libraries (such as FFmpeg and libmpv).
4. Keeps options open for future distribution channels (including the Mac App Store if notarization/sandboxing requirements permit later).

## Decision
We chose the **Mozilla Public License 2.0 (MPL-2.0)**.

## Consequences
- File-level copyleft: changes to existing project files must stay MPL-2.0.
- Clean combination with LGPL components without "viral" GPL propagation to non-GPL files.
- Clear patent grant protections included in MPL-2.0.
