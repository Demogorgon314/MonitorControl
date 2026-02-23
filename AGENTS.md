# Repository Guidelines

## Project Structure & Module Organization
`MonitorControl/` contains the macOS app code, organized into `Model/`, `Support/`, `View Controllers/`, `Extensions/`, and `Assets.xcassets/`.  
`MonitorControlHelper/` is the login helper target.  
`MonitorControlTests/RemoteControl/` holds unit tests for the remote HTTP core.  
`Package.swift` exposes the `RemoteControlCore` library from `MonitorControl/Support/RemoteControl`.  
`MonitorControl.xcodeproj/` defines app build settings and build-phase tooling.

## Build, Test, and Development Commands
- `open MonitorControl.xcodeproj`: open the app project in Xcode and resolve Swift packages.
- `xcodebuild -project MonitorControl.xcodeproj -scheme MonitorControl -configuration Debug build`: CLI build for the app target.
- `swift test`: run SwiftPM tests (`RemoteControlCoreTests`).
- `swiftformat .`: apply repository formatting rules.
- `swiftlint`: run lint checks configured in `.swiftlint.yml`.
- `bartycrouch update -x && bartycrouch lint -x`: update and validate localization strings when changing i18n content.

## Packaging Workflow (.app + .dmg)
- Always use a signed Release build for packaging. Avoid `CODE_SIGNING_ALLOWED=NO`, which creates ad-hoc signatures and can break Accessibility permission recognition.
- Build signed app:
  - `mkdir -p build/logs build/DerivedDataSigned`
  - `xcodebuild -project MonitorControl.xcodeproj -scheme MonitorControl -configuration Release -derivedDataPath build/DerivedDataSigned build > build/logs/xcodebuild-release-signed.log 2>&1`
- Read version/build from the packaged app:
  - `VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/DerivedDataSigned/Build/Products/Release/MonitorControl.app/Contents/Info.plist)`
  - `BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" build/DerivedDataSigned/Build/Products/Release/MonitorControl.app/Contents/Info.plist)`
- Create `.app` and `.dmg` artifacts:
  - `mkdir -p build/artifacts-signed "build/dmg-root-${VERSION}-${BUILD}-signed"`
  - `ditto build/DerivedDataSigned/Build/Products/Release/MonitorControl.app "build/artifacts-signed/MonitorControl-${VERSION}-signed.app"`
  - `ditto build/DerivedDataSigned/Build/Products/Release/MonitorControl.app "build/dmg-root-${VERSION}-${BUILD}-signed/MonitorControl.app"`
  - `ln -s /Applications "build/dmg-root-${VERSION}-${BUILD}-signed/Applications"`
  - `hdiutil create -volname MonitorControl -srcfolder "build/dmg-root-${VERSION}-${BUILD}-signed" -ov -format UDZO "build/artifacts-signed/MonitorControl-${VERSION}-signed.dmg"`
- Sign and verify:
  - `codesign --force --timestamp --sign "<APPLE_DEVELOPMENT_IDENTITY>" "build/artifacts-signed/MonitorControl-${VERSION}-signed.dmg"`
  - `codesign --verify --deep --strict --verbose=2 "build/artifacts-signed/MonitorControl-${VERSION}-signed.app"`
  - `codesign --verify --verbose=2 "build/artifacts-signed/MonitorControl-${VERSION}-signed.dmg"`
- Upload to GitHub Releases:
  - Create draft release: `gh release create "v${VERSION}" "build/artifacts-signed/MonitorControl-${VERSION}-signed.dmg" --repo Demogorgon314/MonitorControl --title "v${VERSION}" --notes "Signed macOS dmg build." --draft`
  - Update existing release asset: `gh release upload "v${VERSION}" "build/artifacts-signed/MonitorControl-${VERSION}-signed.dmg" --repo Demogorgon314/MonitorControl --clobber`
- For external distribution, prefer Developer ID signing + notarization + stapling before publishing.

## Coding Style & Naming Conventions
Use Swift conventions and keep files focused by responsibility. Follow `.swiftformat` defaults used here: 2-space indentation and no padded operators. Use `UpperCamelCase` for types and `lowerCamelCase` for properties/functions. Match existing module boundaries (for example, remote API logic belongs under `Support/RemoteControl`).

## Testing Guidelines
Tests use `XCTest`. Place new remote API/core tests under `MonitorControlTests/RemoteControl/`, name files `*Tests.swift`, and use `test...` method names. Mirror existing patterns (mock services, assert status/payload/error envelope). No explicit repository-wide coverage gate is defined; add tests for all behavior you change, including malformed input and failure paths.

## Commit & Pull Request Guidelines
Recent history uses concise, imperative subjects, often with optional prefixes like `feat(remote): ...`, `build: ...`, or `Fix ... (#1234)`. Keep commits scoped and readable. For PRs, include: purpose, user-visible impact, linked issues, and validation notes. Add screenshots for UI/settings changes. For major design changes, align with the maintainer before large refactors.

## Security & Configuration Tips
Remote HTTP control is LAN-only, disabled by default, and protected by a bearer token stored in Keychain. Never commit tokens, local hostnames, or machine-specific configuration.

## Workflow Orchestration

### 1. Plan Node Default
- Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)
- If something goes sideways, STOP and re-plan immediately - don't keep pushing
- Use plan mode for verification steps, not just building
- Write detailed specs upfront to reduce ambiguity

### 2. Subagent Strategy
- Use subagents liberally to keep main context window clean
- Offload research, exploration, and parallel analysis to subagents
- For complex problems, throw more compute at it via subagents
- One task per subagent for focused execution

### 3. Self-Improvement Loop
- After ANY correction from the user: update `tasks/lessons.md` with the pattern
- Write rules for yourself that prevent the same mistake
- Ruthlessly iterate on these lessons until mistake rate drops
- Review lessons at session start for relevant project

### 4. Verification Before Done
- Never mark a task complete without proving it works
- Diff behavior between main and your changes when relevant
- Ask yourself: "Would a staff engineer approve this?"
- Run tests, check logs, demonstrate correctness

### 5. Demand Elegance (Balanced)
- For non-trivial changes: pause and ask "is there a more elegant way?"
- If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
- Skip this for simple, obvious fixes - don't over-engineer
- Challenge your own work before presenting it

### 6. Autonomous Bug Fixing
- When given a bug report: just fix it. Don't ask for hand-holding
- Point at logs, errors, failing tests - then resolve them
- Zero context switching required from the user
- Go fix failing CI tests without being told how

## Task Management

1. **Plan First**: Write plan to `tasks/todo.md` with checkable items
2. **Verify Plan**: Check in before starting implementation
3. **Track Progress**: Mark items complete as you go
4. **Explain Changes**: High-level summary at each step
5. **Document Results**: Add review section to `tasks/todo.md`
6. **Capture Lessons**: Update `tasks/lessons.md` after corrections

## Core Principles

- **Simplicity First**: Make every change as simple as possible. Impact minimal code.
- **No Laziness**: Find root causes. No temporary fixes. Senior developer standards.
- **Minimal Impact**: Changes should only touch what's necessary. Avoid introducing bugs.
