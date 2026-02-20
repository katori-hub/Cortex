# Build Fix Instructions

## Code Changes Completed ✅

The following code-level fixes have been applied:

1. **Fixed `Tag.swift`** - Changed `var existing` to `let existing` (line 68)
2. **Fixed `CaptureService.swift`** - Removed duplicate `EventSource` enum and switched to using `CortexEventSource` directly
3. **Created `SharedViewComponents.swift`** - Consolidated shared UI components and extensions to avoid duplication
4. **Updated `MenuBarView.swift`** - Removed duplicate extensions (now in SharedViewComponents.swift)
5. **Updated `ShareViewController.swift`** - Kept its own copy of `Color.init(hex:)` since it's in a separate target

## Required Xcode Configuration Steps

You still need to perform these manual steps in Xcode to fix the code signing error:

### Step 1: Add SharedViewComponents.swift to Main Target

1. In Xcode, right-click on your project in the Navigator
2. Select **Add Files to "Cortex"**
3. Navigate to and select `SharedViewComponents.swift`
4. **IMPORTANT**: Make sure only the **Cortex** target is checked (not the extensions)
5. Click **Add**

### Step 2: Remove Bridging Header from Share Extension

1. Select your **project** in the Navigator
2. Select the **CortexShareExtension** target
3. Go to **Build Settings** tab
4. Search for "bridging"
5. Find **Objective-C Bridging Header**
6. **Delete the value** in this field (clear it completely)

### Step 3: Clean and Rebuild

1. Go to **Product → Clean Build Folder** (Cmd+Shift+K)
2. Close and reopen Xcode (optional but recommended)
3. Go to **Product → Build** (Cmd+B)

### Step 4: Verify Signing Configuration

If the error persists, check:

1. Select your project in Navigator
2. For **each target** (Cortex, CortexSafariExtension, CortexShareExtension):
   - Go to **Signing & Capabilities**
   - Ensure the same **Team** is selected
   - Verify **App Groups** capability shows `group.io.bdcllc.cortex`
   - Check that **Bundle Identifier** matches:
     - Main: `io.bdcllc.cortex`
     - Safari: `io.bdcllc.cortex.safari`  
     - Share: `io.bdcllc.cortex.share`

## What Was Fixed and Why

### Code Signing Errors Can Be Caused By:

1. **Compilation failures** - The compiler fails before signing occurs, but the error message shows "CodeSign failed"
2. **Build configuration mismatches** - Bridging headers for pure Swift targets
3. **Duplicate symbols** - Multiple definitions of the same type/extension

### What We Fixed:

- **Duplicate EventSource enum** - `CaptureService.swift` was defining its own `EventSource` when `CortexEventSource` already existed in `Event.swift`
- **Missing shared components** - `MainWindowView.swift` was referencing `StatusDot` and extensions that were only defined in `MenuBarView.swift`
- **Code warnings** - Fixed the `var`→`let` warning in `Tag.swift`

These issues would cause compilation to fail, resulting in a "CodeSign failed" error message.

## Testing After Build Succeeds

Once the build completes successfully:

1. Run the app (Cmd+R)
2. Verify the menu bar icon appears
3. Test capturing a URL from the menu bar popover
4. Test the Safari extension (if enabled)
5. Test the Share extension from another app

## Still Having Issues?

If you still see the code signing error after following all steps:

1. Check the **full build log** in Xcode (View → Navigators → Reports)
2. Look for the **first error** in the log (not the CodeSign error)
3. The root cause will usually be a Swift compilation error earlier in the log
4. Share that error message for further help

---

Remember: "Command CodeSign failed" is often a symptom, not the root cause. The real error is usually earlier in the build process!
