# macOS permissions for a fresh Mac dev setup (no MDM)

Scope: Apple silicon, macOS 26.6.2 (25G83) "Tahoe", admin user, no MDM. Target: what `den`
must tell the human to click, how a script can open the pane, how the app gets into the list,
and how to detect the grant afterwards.

Read-only facts about this machine were taken on 2026-11-18 and are marked **measured**. Everything
else carries a URL. Anything I could not source is marked **Not verified** at the point of use, and
listed again at the end.

**Established, not re-researched:** no programmatic grant without MDM; `tccutil` only resets (its man
page documents the single `reset` command — **measured**); PPPC needs MDM; Microphone, Camera and
Screen Recording always need a human; grants bind to the code-signing identity.

---

## 0. The short version

1. Grant everything to **`Rex Server.app`** (`com.superlogical.rex.server`), not to `Rex Beta.app`.
   Every shell in a Rex tab belongs to the server.
2. Do **not** grant Full Disk Access to a terminal or to Rex unless a specific tool needs it. Voice
   Memos, Messages and Safari data are FDA-only, but the setup only needs Voice Memos.
3. Nothing in this setup needs **Local Network**: the Rex local server is a Unix socket, and loopback
   plus a Tailscale `100.x` address are not "local network" traffic.
4. Do **not** enable **Developer Tools** for the terminal. It does not speed up Gatekeeper or XProtect
   scans; it lets an app run software that fails the security policy.
5. Touch ID for `sudo` goes in `/etc/pam.d/sudo_local`, with `pam_reattach` above `pam_tid` because
   Rex's server is a background process, not a login-session process.

---

## 1. Rex and the "responsible process" — the key question

### 1.1 What the vendor says

Rex documents its own privacy API, `server.apple.privacy_status`:

> "macOS decides privacy permissions for the app it holds responsible for a process. Every shell and
> program the server runs belongs to the server, so they all get the permissions listed here, whatever
> the app that shows their terminals was allowed."
> — [Rex Server API, `server.apple.privacy_status`](https://www.superlogical.com/rex/docs/reference/api#serverappleprivacy_status)

> "`responsible_path` is the executable macOS holds responsible for the server. The permissions belong
> to the app that contains it. When the server was started in the foreground from a terminal app, that
> is the terminal app."
> — same page

So: **a CLI in a Rex tab is covered by `Rex Server.app`, not `Rex Beta.app`.** Rex's own command
palette agrees — the action that fixes permissions is in the Mac client but it exists to open the
server's panes: `client.permissions` / "Grant System Permissions…" with the index terms "full disk
access screen recording system audio grant allow system settings tcc"
([Mac Actions](https://www.superlogical.com/rex/docs/reference/mac-actions#action-client-permissions)).

The bundle is built for exactly this. **Measured** on this Mac:

| App | Bundle id | Display name | Notes |
| --- | --- | --- | --- |
| `~/Applications/Rex Beta.app` | `com.superlogical.rex` | `Rex` | Developer ID `Superlogical, Inc. (AG92C3PT77)` |
| `…/RexServer/Versions/Current/Rex Server.app` | `com.superlogical.rex.server` | `Rex Server` | same team, `LSUIElement = true` |

`Rex Server.app` carries the usage strings, and they name the terminal as the requester:

> `NSMicrophoneUsageDescription` = "A program running in a Rex terminal wants to use your microphone.
> Rex does not record audio itself."
> `NSAppleEventsUsageDescription` = "A program running in a Rex terminal wants to control other apps
> with AppleScript. Rex does not send these commands itself."

**Measured** by reading both `Contents/Info.plist` files with `plutil -p`. The server also carries
`NSCameraUsageDescription`, `NSAudioCaptureUsageDescription`, `NSLocalNetworkUsageDescription`,
`NSContactsUsageDescription`, `NSCalendarsUsageDescription`, `NSPhotoLibraryUsageDescription`,
`NSLocationUsageDescription`, `NSBluetoothAlwaysUsageDescription`.

Why the usage string matters: a process with no matching `NS*UsageDescription` does not get a prompt,
it gets a silent denial. That mechanism is documented per key, e.g.
[`NSFileProviderDomainUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsfileproviderdomainusagedescription).
The Rex server has all of them, so it can ask for everything a tab might need.

### 1.2 How TCC picks the responsible process, in general

- Child processes inherit the parent's responsibility unless the parent *disclaims* it. Apple's launch
  constraint documentation states the rule for XPC and helpers: "The app that initiates a … XPC
  connection is responsible for launching the XPC service. An app that launches a helper process
  directly is both the parent process and the responsible process for the helper."
  — [Apple: Applying launch environment and library constraints](https://developer.apple.com/documentation/security/applying-launch-environment-and-library-constraints)
- A process launched by `launchd` is its own responsible process; a parent can break the chain with
  `responsibility_spawnattrs_setdisclaim`, which is how editors stop becoming responsible for the
  programs they launch — [torarnv/disclaim](https://github.com/torarnv/disclaim).
- The measurement command is `launchctl procinfo <pid>`, which prints `responsible path`. It needs
  root (**measured**: `launchctl procinfo` replies "This subcommand requires root privileges"). The
  technique is described by the disclaim author and by Qt's write-up of the same problem:
  [The Curious Case of the Responsible Process](https://www.qt.io/blog/the-curious-case-of-the-responsible-process).

### 1.3 Measured on this Mac

```console
$ rex api call server.apple.privacy_status
{"services":[{"service":"full_disk_access","status":"granted"},
             {"service":"screen_recording","status":"granted"},
             {"service":"microphone","status":"not_determined"},
             {"service":"camera","status":"not_determined"}],
 "responsible_path":"/Users/acastro/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"}
```

Two things matter here:

1. The service names Rex reports are `full_disk_access`, `screen_recording`, `microphone`, `camera`
   (schema: `services[]` = `{service, status}`, `status` ∈ `granted | denied | not_determined | unknown`,
   plus `responsible_path` — `rex api describe server.apple.privacy_status --json`, **measured**).
2. The answer is per-server, and it is read without prompting: "Reading the permissions never makes
   macOS ask the person anything" ([API docs](https://www.superlogical.com/rex/docs/reference/api#serverappleprivacy_status)).

**A trap, measured.** The shell that ran the checks above had this process chain:

```text
zsh ← opencode-pty ← opencode (ppid 1, launchd)
```

That chain does not pass through `Rex Server`, and in it every protected read failed
(`Operation not permitted` on `~/Library/Application Support/com.apple.TCC/TCC.db`,
`~/Library/Safari/History.db`, `~/Library/Messages/chat.db`, and `tmutil listbackups`). So:

> Do not infer the responsible process from "Rex is open" or from the process tree alone. Measure it
> with `launchctl procinfo <pid>` (root), or ask the app (`rex api call server.apple.privacy_status`).
> A tool launched by a background agent can carry a different TCC identity from the Rex server.

---

## 2. Permission tables

Legend for **Detect**: a command that exits 0 / prints the grant without prompting. Pane URLs are the
`x-apple.systempreferences` form; the scheme is `x-apple.systempreferences` only — `x-apple.systemsettings`
has no registered handler on macOS 26.4, and both the current extension id and the legacy
`com.apple.preference.security` resolve to System Settings
([measured on macOS 26.4](https://github.com/theJayTea/WritingTools/pull/261)). **Measured** here: the
Privacy & Security extension is `com.apple.settings.PrivacySecurity.extension`, with
`allowsXAppleSystemPreferencesURLScheme = 1` and `legacyBundleIdentifier = com.apple.preference.security`.

Base URL: `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?<anchor>`

### 2.1 Rex Server (`com.superlogical.rex.server`) — the app every CLI inherits from

| Permission | Why this setup needs it | Pane URL (anchor) | How to register | How to detect | Source |
| --- | --- | --- | --- | --- | --- |
| Full Disk Access (`kTCCServiceSystemPolicyAllFiles`) | Read Voice Memos (`CloudRecordings.db`), any `~/Library` data a skill touches, and let `sqlite3`/`head` probes work | `…?Privacy_AllFiles` | Add `Rex Server.app` with **+**, or let a protected read trigger the row | `rex api call server.apple.privacy_status` → `full_disk_access`; plus a real probe: `head -c 4 "$HOME/Library/Application Support/com.apple.TCC/TCC.db"` (see §6.2) | [Rex API](https://www.superlogical.com/rex/docs/reference/api#serverappleprivacy_status), [Apple: controlling app access to files](https://support.apple.com/guide/security/controlling-app-access-to-files-secddd1d86a6/web) |
| Accessibility (`kTCCServiceAccessibility`) | Peekaboo UI automation, any AX client, `osascript` keystrokes into apps | `…?Privacy_Accessibility` | Run `peekaboo permissions request accessibility`, or tick the row after the first AX call | `peekaboo permissions status --all-sources --json`; `AXIsProcessTrusted` for in-process tools | [peekaboo permissions](https://github.com/openclaw/Peekaboo/blob/main/docs/commands/permissions.md), [AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions) |
| Screen & System Audio Recording (`kTCCServiceScreenCapture`) | Peekaboo screenshots, `scribe` grabbing system audio | `…?Privacy_ScreenCapture` (Tahoe lists also accept `Privacy_AudioCapture`) | `peekaboo permissions request screen-recording`, or first capture attempt | `peekaboo permissions status --json`; `CGPreflightScreenCaptureAccess()` | [Apple help: Screen Recording pane](https://support.apple.com/guide/mac-help/change-privacy-security-settings-on-mac-mchl211c911f/mac), [CGPreflightScreenCaptureAccess](https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess()) |
| Microphone (`kTCCServiceMicrophone`) | Only if a tab records audio. Hex is a separate app and does its own | `…?Privacy_Microphone` | First `AVCaptureDevice.requestAccess` from a tab, or the pane after a failed capture | `rex api call …` → `microphone`; `AVCaptureDevice.authorizationStatus(for: .audio)` | [AVCaptureDevice.authorizationStatus](https://developer.apple.com/documentation/avfoundation/avcapturedevice/authorizationstatus(for:)), [Rex API](https://www.superlogical.com/rex/docs/reference/api#serverappleprivacy_status) |
| Automation / Apple Events (`kTCCServiceAppleEvents`, per target app) | `osascript` into Brave/Chrome/Edge (browser control), `osascript` into System Events | `…?Privacy_Automation` | First `osascript` to that target; the prompt names the target app | `osascript -e 'tell application "Brave Browser" to get name'` (prompts once, then `-1743` when denied). Non-prompting: `AEDeterminePermissionToAutomateTarget(..., false)` returns `-1744` for "not asked" but cannot tell "denied" apart | [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events), [Platform Security table](https://support.apple.com/guide/security/controlling-app-access-to-files-secddd1d86a6/web) |
| Input Monitoring (`kTCCServiceListenEvent`) | Not needed by Peekaboo (it uses Accessibility) and not needed by Hex | `…?Privacy_ListenEvent` | Only if a tool asks | `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` | [IOHIDCheckAccess](https://developer.apple.com/documentation/iokit/3181573-iohidcheckaccess), [peekaboo permissions](https://github.com/openclaw/Peekaboo/blob/main/docs/commands/permissions.md) |
| Local Network | Not needed — see §4 | `Privacy & Security > Local Network` (no verified anchor) | – | `rex api call …` does not report it; nothing to check | [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy), [Rex privacy](https://www.superlogical.com/rex/docs/reference/privacy) |

Watch out for **two** rows: `Rex Beta.app` may also appear if the app itself touches a file (drag and
drop onto a terminal uses `server.apple.grant_file_access`, which the server mediates —
[API](https://www.superlogical.com/rex/docs/reference/api#serverapplegrant_file_access)). The server's
row is the one that matters.

### 2.2 Peekaboo (`/opt/homebrew/bin/peekaboo`, Homebrew)

| Permission | Why | Pane URL | How to register | How to detect | Source |
| --- | --- | --- | --- | --- | --- |
| Accessibility | Clicks, typing, element queries | `…?Privacy_Accessibility` | `peekaboo permissions request accessibility` | `peekaboo permissions status --all-sources --json` | [docs/commands/permissions.md](https://github.com/openclaw/Peekaboo/blob/main/docs/commands/permissions.md) |
| Screen Recording | Window capture | `…?Privacy_ScreenCapture` | `peekaboo permissions request screen-recording` | same command | [peekaboo.sh/permissions](https://peekaboo.sh/permissions.html) |
| Event Synthesizing (optional) | Background key/pointer delivery | same Accessibility pane | `peekaboo permissions request event-synthesizing` | same command | [peekaboo.sh/permissions](https://peekaboo.sh/permissions.html) |

Two facts that change behaviour:

- Peekaboo needs **macOS 15+**, and it does **not** use Automation: "Peekaboo's application, Dock, and
  UI operations use native macOS APIs. It does not probe, request, or require Automation (AppleScript)
  permission" ([permissions docs](https://github.com/openclaw/Peekaboo/blob/main/docs/commands/permissions.md)).
- A Homebrew upgrade moves the binary to a new Cellar path and TCC treats it as a new client; the fix
  is to remove the stale row and re-grant ([peekaboo.sh](https://peekaboo.sh/permissions.html)).
  **Measured** on this Mac: a Bridge daemon at `~/Library/Application Support/Peekaboo/daemon.sock`
  answers by default, and it reported `Screen Recording: false` while the local CLI reported `true`.
  Grant to whichever host the `Source:` line names; `--no-remote` forces the local one.

### 2.3 Browsers (Brave, Chrome, Edge) — not used

**Not used by `den`.** Browser control goes through the browse relay (the Mac's
`browse serve` on `127.0.0.1:19988`, reached from a VM agent through the Rex
tunnel), not through Apple Events. So `den` asks for no Automation grant and does
not check "Allow JavaScript from Apple Events"; leave it off. The rows below stay
as reference for anything that goes back to `osascript`. Facts, with sources:

| Permission / setting | Why | Where | How to register | How to detect | Source |
| --- | --- | --- | --- | --- | --- |
| Automation (Rex Server → Brave/Chrome/Edge) | `osascript` tab control, URL/title reads | `…?Privacy_Automation` | First `osascript` to that browser; the prompt pairs the two apps | `osascript -e 'tell application "Brave Browser" to get name'` | [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events) |
| Allow JavaScript from Apple Events | `execute javascript` is refused without it (`-1723`) | Browser menu: **View > Developer > Allow JavaScript from Apple Events** | Human tick; it is **per profile** | Read the per-profile pref (below) or check the menu's `AXMenuItemMarkChar` (**Not verified**) | [chromium.org/developers/applescript](https://www.chromium.org/developers/applescript/), [Chromium `pref_names.h`](https://chromium.googlesource.com/chromium/src/+/main/chrome/common/pref_names.h) |

**The defaults key you are probably looking for does not exist in the supported form.** Chromium stores
it as a profile pref, not an `NSUserDefaults` domain:

```c
// chrome/common/pref_names.h, line 418
inline constexpr char kAllowJavascriptAppleEvents[] =
    "browser.allow_javascript_apple_events";
```

So `defaults write com.google.Chrome AppleScriptEnabled -bool true` (widely repeated) is **not** the
current mechanism. The pref lives in
`~/Library/Application Support/<vendor>/<browser>/<Profile>/Preferences` as
`browser.allow_javascript_apple_events`. **Measured** on this Mac: `Google Chrome/Default/Preferences`
and `BraveSoftware/Brave-Browser/Default/Preferences` both have no such key, i.e. off (the default).

What works from a script without support: read the pref, never write it. Writing a browser profile
file while the browser runs is unsupported (**Not verified** that it is safe).

### 2.4 Voice Memos (`scribe`)

| Permission | Why | Pane URL | How to register | How to detect | Source |
| --- | --- | --- | --- | --- | --- |
| Full Disk Access | `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db` is TCC-protected | `…?Privacy_AllFiles` | Add `Rex Server.app`; first read attempt creates the row | `head -c 4 "<db path>" >/dev/null` → 0 means granted | [voice-memos-skill](https://github.com/grapeot/voice-memos-skill) ("protected by TCC … grant Full Disk Access"), [voice-memo-clip-player](https://github.com/pierwill/voice-memo-clip-player), [voicememowhisper](https://github.com/xyb/voicememowhisper/blob/main/docs/technical_details.md) |

Apple does not publish which TCC class covers a Group Container. Three independent tools say Full Disk
Access, and the path is absent on this Mac (**measured**: `…/group.com.apple.VoiceMemos.shared/Recordings`
does not exist yet, because Voice Memos has never recorded here), so this is **not verified locally**.
Note also there is no "Voice Memos" pane: FDA is the only switch that reaches it.

### 2.5 Obsidian vault in OneDrive

| Permission | Why | Pane URL | How to register | How to detect | Source |
| --- | --- | --- | --- | --- | --- |
| Files & Folders for the OneDrive domain (or Full Disk Access) | Read/write `~/Library/CloudStorage/OneDrive-Personal/...` | `…?Privacy_FilesAndFolders` | Let the first open of a file prompt; or add the app under Files & Folders | Enumerate a file: `head -c 4 "<vault>/.obsidian/app.json"` | [NSFileProviderDomainUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsfileproviderdomainusagedescription), [OneDrive File Provider sync root](https://techcommunity.microsoft.com/blog/onedriveblog/inside-the-new-files-on-demand-experience-on-macos/3058922) |

**Measured** on this Mac: listing `~/Library/CloudStorage/OneDrive-Personal` and walking its
subdirectories worked from a process with no Files & Folders or FDA grant, and no prompt appeared.
Directory enumeration is not the protected operation; opening the domain's files is. Because the Rex
Server app ships no File Provider-specific key beyond what it has, a **read** is the only reliable
test. Whether a CLI read of an OneDrive file prompts, and which pane then shows the entry, is
**Not verified** for macOS 26.

Practical advice for `den`: keep the vault read/write inside Rex tabs (the server row is what TCC
checks), and do not grant FDA for OneDrive unless a read actually fails.

### 2.6 HiDock over USB (`pyusb`)

| Permission | Why | Pane URL | How to register | How to detect | Source |
| --- | --- | --- | --- | --- | --- |
| none | No USB privacy class exists in Privacy & Security | – | – | `system_profiler SPUSBDataType \| grep -i hidock` | [Apple: controlling app access to files](https://support.apple.com/guide/security/controlling-app-access-to-files-secddd1d86a6/web) lists the gated classes; USB is not one |

**Not verified**: that `pyusb` on macOS 26 needs no entitlement. The claim "no TCC class for USB" rests
on the absence of any USB entry in Apple's privacy lists (the same page enumerates Accessibility, Full
Disk Access, Files and Folders, Automation, Camera, Microphone, Screen Recording). If libusb asks for
permission, it would surface as a **Removable Volumes** row (`Privacy_RemovableVolume`), which the pane
metadata on this Mac does contain.

### 2.7 Hex (`anomaly.hex`) — voice dictation

| Permission | Why | Pane URL | How to register | How to detect | Source |
| --- | --- | --- | --- | --- | --- |
| Microphone | Records dictation | `…?Privacy_Microphone` | Hex's own onboarding prompts | Hex UI; the pane row | [Hex feature map](https://github.com/anomalyco/hex/blob/main/docs/features/README.md) |
| Accessibility | Sees its shortcut in every app, pastes the text | `…?Privacy_Accessibility` | Drag `Hex.app` into the list (Hex's guide) | `AXIsProcessTrusted` in-process; the pane row | [Hex 3.0.0 release notes](https://github.com/anomalyco/hex/releases/tag/v3.0.0) |
| Screen Recording | Only for the "Annotate" feature | `…?Privacy_ScreenCapture` | macOS asks on first Annotate | Hex UI | [Hex feature map](https://github.com/anomalyco/hex/blob/main/docs/features/README.md) |

Hex explicitly does **not** need Input Monitoring ("Accessibility covers the shortcut") and installs
as `anomaly.hex` from 3.0.0, a new identity that keeps none of the old grants
([release notes](https://github.com/anomalyco/hex/releases/tag/v3.0.0)). Because the identity changed,
a Mac that had `com.kitlangton.hex2` rows keeps stale entries that make the new row look grey — the
vendor's own fix is `tccutil reset` for the retired ids
([feature map](https://github.com/anomalyco/hex/blob/main/docs/features/README.md)).

### 2.8 VS Code + Remote-SSH, and the Lima VM

| Permission | Why | Verdict | Source |
| --- | --- | --- | --- |
| Local Network | Remote-SSH to a Lima VM over `127.0.0.1:<port>` | Not needed: loopback is not a local network address. TN3179 defines a local network as "an IP network associated with a broadcast-capable network interface … Wi-Fi and Ethernet, but not cellular (WWAN) or VPN" | [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) |
| Local Network | A Tailscale `100.x` address | Not needed: the tailnet arrives on a VPN (utun) interface, which TN3179 excludes | same |
| Local Network | Any command-line tool | Auto-allowed: "Command-line tools run from Terminal or over SSH, including any child processes they spawn" | same |
| Automation | None | – | – |

Loopback is not named in TN3179; the exclusion follows from its definition (a loopback address is not
on a broadcast-capable interface). **Not verified** by an Apple sentence that says "127.0.0.1 is exempt".

TN3179 also explains why a `launchd` **agent** is the exception: daemons are auto-allowed, agents are
not, and a short-lived agent can fail to show the alert at all (FB16131937). That matters for the
`vm-up` login agent — see §3.

### 2.9 Background items (`~/Library/LaunchAgents`)

| Item | Why | Where it appears | How to approve | How to detect | Source |
| --- | --- | --- | --- | --- | --- |
| `io.mac-bootstrap.vm-up` | Starts the VM at login | System Settings > General > **Login Items & Extensions** | Toggle in that pane, or the "Background Items Added" notification | `sudo sfltool dumpbtm` → look for the label, `Disposition:` must contain `enabled`, `allowed` | [Apple: manage login items and background tasks](https://support.apple.com/guide/deployment/manage-login-items-background-tasks-mac-depdca572563/web), [eclecticlight.co](https://eclecticlight.co/2025/12/03/manage-login-and-background-items/) |
| `io.lima-vm.autostart.agent` | Lima starts its VM at login | same | same | same | [Lima docs](https://lima-vm.io/docs/config/), same dump |

Facts that decide the design:

- macOS 13+ rolls login items, agents and daemons into Background Task Management (BTM), stored at
  `/private/var/db/com.apple.backgroundtaskmanagement/BackgroundItems-v*.btm`, and shows one approval
  surface in Login Items & Extensions ([Apple deployment guide](https://support.apple.com/guide/deployment/manage-login-items-background-tasks-mac-depdca572563/web)).
- Only **SMAppService** exposes a programmatic state (`SMAppService.status`) and
  `openSystemSettingsLoginItems()`; a plist dropped into `~/Library/LaunchAgents` by hand gets no such
  API, only `statusForLegacyPlist(at:)` for apps that ship the plist inside a bundle
  ([SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice),
  [`register()`](https://developer.apple.com/documentation/servicemanagement/smappservice/register())).
- `sfltool dumpbtm` is **undocumented**: the man page still describes only `archive`, and the usage
  line (`sfltool csinfo|dumpbtm|archive|clear|resetbtm|resetlist|list|list-info`) is the only help
  (**measured**). It needs root. `Disposition` is a bit field: `0x1` enabled, `0x2` allowed, `0x4`
  hidden, `0x8` notified ([macforensics](https://www.macforensics.app/en/artifacts/login-items-btm),
  [DumpBTM](https://github.com/objective-see/DumpBTM/)).
- **There is no supported "pre-approve" without MDM.** MDM can auto-approve by Team ID, bundle id or
  label prefix through a configuration profile ([Apple deployment guide](https://support.apple.com/guide/deployment/manage-login-items-background-tasks-mac-depdca572563/web));
  nothing local can.

`den`'s practical check: `sudo sfltool dumpbtm` is root-only and its output is not a stable format, so
it belongs in `den doctor --verbose`, not in the hot path. The cheap check is
`launchctl print gui/$(id -u)/io.mac-bootstrap.vm-up` (0 when loaded) plus the VM itself; approval
state only matters the first login after install.

### 2.10 Everything else a fresh setup usually trips on

| Item | Verdict | Source |
| --- | --- | --- |
| Notifications for Rex | No documented CLI check. `rex` has no notification API and has no row in `com.apple.ncprefs` (**measured**; 96 apps listed, none Superlogical). The only check is `UNUserNotificationCenter.getNotificationSettings`, in-process | [UNUserNotificationCenter](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter) |
| Keychain prompts for `gh` / `op` | Normal: first use asks to unlock the login keychain. `op` with the desktop app uses biometric unlock instead of a prompt | [1Password CLI docs](https://developer.1password.com/docs/cli/) |
| Gatekeeper prompt for a downloaded app | Right-click > Open no longer exists on Sequoia+; approve in Privacy & Security | [Apple developer news, 2024-08-06](https://developer.apple.com/news/?id=saqachfa) |
| Touch ID for sudo | See §5 | – |

---

## 3. Background items, in detail

The `vm-up` agent is the one item in this repo that lands in BTM. Three consequences:

1. **First login after install** shows "Background Items Added". Nothing breaks, but the VM does not
   start until the human approves. `den vm status` must say "waiting for approval" rather than "failed".
2. **`Vendor`/`AssociatedBundleIdentifiers`** is how the pane groups an agent under an app name
   instead of the developer name ([Apple](https://support.apple.com/guide/deployment/manage-login-items-background-tasks-mac-depdca572563/web)). A bare plist shows as "Superlogical" or the label.
3. **Do not use `sfltool resetbtm`** to "fix" a stuck item — it rebuilds the whole store and drops
   every user decision ([eclecticlight.co](https://eclecticlight.co/2025/12/03/manage-login-and-background-items/)).

Lima's `io.lima-vm.autostart.agent` is a normal LaunchAgent and needs the same approval.

---

## 4. Local Network, in detail

- What counts: "A local network is an IP network associated with a broadcast-capable network
  interface. Such interfaces include Wi-Fi and Ethernet, but not cellular (WWAN) or VPN." All multicast
  (`224.0.0.0/4`, `ff00::/8`) and `255.255.255.255` are local ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)).
- Who is exempt on macOS: daemons started by `launchd`, anything running as root, and **command-line
  tools run from Terminal or over SSH, including children** (same page). `launchd` *agents* are not
  exempt.
- Rex is a **Unix socket** client on this machine: "Rex for Mac runs a Rex server on your Mac and talks
  to it over a Unix socket, so that traffic never leaves your machine. The app starts it without any
  network listeners or Tailscale" ([Rex privacy](https://www.superlogical.com/rex/docs/reference/privacy)).
  No listener, no local network operation.
- The one real case: `ssh` to a Lima VM is loopback; `ssh` to a LAN host from a *GUI app* would prompt.
  The Rex server is not a GUI app and its children are command-line tools, so the exemption applies.
- The pane exists ("Settings > Privacy & Security > Local Network" — TN3179) but on macOS 26.6 it has
  **no anchor** in Apple's own pane metadata (**measured**: the Privacy & Security search-terms file
  lists 34 anchors, none for Local Network, while the extension binary does contain a
  `PrivacyLocalNetworkService`). `Privacy_LocalNetwork` is unverified. Open the Privacy pane and scroll.
- A `launchd` agent that dies quickly will not even show the alert (FB16131937, same page). If `vm-up`
  ever opens a LAN socket, do not exit on failure.

---

## 5. Touch ID for sudo

**Measured** on macOS 26.6.2 — `/etc/pam.d/sudo`:

```text
# sudo: auth account password session
auth       include        sudo_local
auth       sufficient     pam_smartcard.so
auth       required       pam_opendirectory.so
...
```

`sudo_local` does not exist yet, and Apple ships `/etc/pam.d/sudo_local.template` with the line already
written and commented:

```text
# sudo_local: local config file which survives system update and is included for sudo
# uncomment following line to enable Touch ID for sudo
#auth       sufficient     pam_tid.so
```

`/usr/lib/pam/pam_tid.so.2` exists (**measured**). Because `sudo` `include`s `sudo_local`, a system
update replaces the Apple files and leaves yours alone — which is the whole point of the mechanism.

**Why `pam_reattach` is needed here.** `pam_tid` can only draw the prompt from the user's GUI login
session. A background session — tmux, screen, an IDE terminal, or a `launchd`-parented process like
`Rex Server` (`LSUIElement = true`, **measured**) — has no route to it, so the module fails and the
`sufficient` line falls through to the password. `pam_reattach` moves `sudo` into the active login
session first ([pam_reattach](https://github.com/fabianishere/pam_reattach/)):

```text
# /etc/pam.d/sudo_local
auth       optional       /opt/homebrew/lib/pam/pam_reattach.so
auth       sufficient     pam_tid.so
```

- Order matters: reattach **above** `pam_tid`.
- `optional`, so a missing module degrades to a password prompt instead of locking you out
  ([pam_reattach README](https://github.com/fabianishere/pam_reattach/)).
- Apple silicon + Homebrew: PAM does not search `/opt/homebrew`, so the full path is required (same
  README). **Measured**: `/opt/homebrew/lib/pam/` does not exist before `brew install pam-reattach`.
- Sessions over SSH keep asking for the password by design (`pam_tid` refuses); add `ignore_ssh` if a
  shared tmux session is used from both places (same README).

**Not verified**: that Rex specifically loses the Touch ID prompt. **Measured**: two `Rex Server`
processes were running here — one parented by `Rex Beta.app` (pid 5310 → 5316), one parented by a
non-Rex process (82628 → 82648). `Rex.app` is a GUI app, so the prompt may well work for the first one.
`pam_reattach` costs nothing (`optional`) and removes the question, so include it.

`den` should write this file only when `pam-reattach` is installed, and check with
`grep -c pam_tid /etc/pam.d/sudo_local`.

---

## 6. Detection reference

### 6.1 Cheap, supported, no prompt

```sh
# Everything Rex's server knows about its own TCC state, plus who is responsible
rex api call server.apple.privacy_status

# Screen Recording, Accessibility, Event Synthesizing, per host
peekaboo permissions status --all-sources --json

# Developer Tools switch (Apple's own tool)
/usr/sbin/DevToolsSecurity -status

# A grant that only exists as a Settings toggle
ls -l /etc/pam.d/sudo_local
```

`peekaboo permissions status` routes to a Bridge daemon if one is healthy, so always read the `Source:`
line or pass `--all-sources` ([docs](https://github.com/openclaw/Peekaboo/blob/main/docs/commands/permissions.md)).
**Measured** here: Bridge reported Screen Recording `false` while the local CLI reported `true`.

### 6.2 The TCC databases are not a reliable detector

The classic query is real:

```sql
select client, service, auth_value from access
 where service = 'kTCCServiceSystemPolicyAllFiles' and auth_value;   -- 2 = allowed
```

`auth_value` is an integer (`0` denied, `2` allowed), and the old column was `allowed`
([apple.stackexchange](https://apple.stackexchange.com/questions/362865/macos-list-apps-authorized-for-full-disk-access)).
Apple documents none of this: the schema, the column names and the `kTCCService*` identifiers are
reverse-engineered, and the identifiers drift between releases.

On this machine the read fails from an unprivileged agent:

```console
$ sqlite3 "file:$HOME/Library/Application Support/com.apple.TCC/TCC.db?mode=ro" .tables
Error: unable to open database "…": authorization denied
$ head -c 4 "/Library/Application Support/com.apple.TCC/TCC.db"
head: …: Operation not permitted
```

So the only safe use is as a **probe**, not a query: if the open succeeds, the responsible process has
Full Disk Access; if it fails, it does not. Two caveats:

- The probe answers for the process that runs it, i.e. the responsible process. Run it from the same
  context as the tool you are checking.
- On macOS 15+ the TCC directory mode can make even an FDA process fail, which is a known false negative
  ([seb-mac #655](https://github.com/SafeExamBrowser/seb-mac/issues/655),
  [seb-mac #647](https://github.com/SafeExamBrowser/seb-mac/issues/647)). Treat a failure as "check the
  pane", never as "revoke".

For the same reason, do not shell out to `sqlite3` and expect it to inherit your app's FDA: the
subprocess has its own identity ([omi #5764](https://github.com/BasedHardware/omi/pull/5764)).

### 6.3 XPC / helper tip

`launchctl procinfo <pid>` is the only direct answer to "who is responsible", and it needs root
(**measured**). `den doctor` can call it behind `sudo -n`, which is already a preflight need.

---

## 7. Developer Tools: recommend **no**

Apple's own description of the pane: "Developer Tools — Allow apps to run software that doesn't meet
the system's security policy" ([Apple help](https://support.apple.com/guide/mac-help/change-privacy-security-settings-on-mac-mchl211c911f/mac),
[dedicated page](https://support.apple.com/guide/mac-help/control-ability-apps-run-software-meet-mchlc5fb7f9c/mac)).
It is a **policy override for the listed app**, not a performance switch.

The separate Apple switch is `DevToolsSecurity`, and its man page is explicit about scope: it changes
the authorization policy so that an admin or `_developer` member "does not need to enter an additional
password to use the Apple-code-signed debugger and performance analysis tools" (**measured**:
`man DevToolsSecurity`, current at macOS 26.6). It is about `task_for_pid`/`dtrace` authorization, not
about Gatekeeper.

Gatekeeper scanning is unchanged by either switch: a malicious-content scan happens on first launch of
quarantined software on the Launch Services path, and every loaded binary gets a scan regardless of
quarantine ([WWDC19 "Advances in macOS Security"](https://developer.apple.com/videos/play/wwdc2019/701/),
[Apple Platform Security](https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web)).
A newly built binary has no quarantine attribute (`com.apple.quarantine` is set by the downloading app),
so it does not even take the first-launch path.

**Recommendation for `den`:** do not enable Developer Tools, do not run `DevToolsSecurity -enable`, and
do not run `spctl developer-mode enable-terminal`. `spctl`'s own help says it only "Add Terminal as a
developer tool" (**measured**: `spctl --help`, "Developer Mode Usage"), i.e. it grants the built-in
Terminal a policy override that this setup does not need. If a tool ever needs it, add that one app in
`…?Privacy_DevTools` and record why.

---

## 8. What `den` should do — ordered

Front-loaded human steps, because a phase that needs a click must not block a later one.
Every step is skippable and must never fail the run (contract rule 3).

**Preflight, once, with the human at the keyboard**

1. Print one page: "These three clicks need you; everything else is automatic." Then open the
   panes in this order, with `open -g` and a 2 s gap:
   1. `…?Privacy_AllFiles` — add **Rex Server.app**
      (`~/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app`).
      Not `Rex Beta.app`.
   2. `…?Privacy_Accessibility` — add **Rex Server.app**. Or run
      `peekaboo permissions request accessibility` and let the prompt do it.
   3. `…?Privacy_ScreenCapture` — add **Rex Server.app**, or
      `peekaboo permissions request screen-recording`.
   4. General > **Login Items & Extensions** — approve `io.mac-bootstrap.vm-up` and Lima.
2. Tell the human to **quit and reopen Rex** after the grants. TCC reads the identity at launch for some
   services, and Hex's own docs confirm the pattern ("On in System Settings, unusable until relaunch").
3. Run the probes and print a table: `rex api call server.apple.privacy_status`,
   `peekaboo permissions status --all-sources --json`, `DevToolsSecurity -status`,
   `ls /etc/pam.d/sudo_local`.

**Phases, unattended**

4. `sudo-touchid`: install `pam-reattach` (brew), write `/etc/pam.d/sudo_local` with `optional`
   reattach + `sufficient pam_tid`, back up any existing file, verify with `grep`. Skip when the file
   already has `pam_tid`.
5. `den doctor` additions: responsible path behind `sudo -n launchctl procinfo`, background item state
   via `sudo -n sfltool dumpbtm` (verbose only), and the stale-row warning for Hex
   (`com.kitlangton.hex2`, `com.kitlangton.Hex`, `anomaly.hex`).
6. Never call `tccutil reset` from a phase. The one legitimate use is the stale-identity cleanup Hex
   documents, and that is the app's job, not the setup's.

**Do not**

7. Do not grant Full Disk Access to Terminal, iTerm, VS Code or Rex Beta "just in case". FDA is
   system-wide in effect: granting it to one app lets everything that app runs inherit it.
8. Do not edit a TCC database. On macOS 26 it is not writable by a normal admin process, and the write
   is the thing MDM exists for.
9. Do not promise that a grant survives a reinstall of the app. TCC keys on the code identity: a
    re-signed build, a new Cellar path, or a new bundle id is a new client
    ([peekaboo.sh](https://peekaboo.sh/permissions.html), [Hex 3.0.0 notes](https://github.com/anomalyco/hex/releases/tag/v3.0.0)).

---

## 9. Claims I could not source

- Apple never states that `127.0.0.1` is exempt from Local Network privacy; the conclusion comes from
  TN3179's definition of a local network (broadcast-capable interface, not VPN).
- Apple does not document which TCC class protects `~/Library/Group Containers/group.com.apple.VoiceMemos.shared`.
  Three third-party tools say Full Disk Access; it is unverified locally (no Voice Memos data on this Mac).
- Whether editing a browser profile's `Preferences` while the browser runs is safe. Not verified.
- Whether `pyusb`/libusb needs any grant on macOS 26. No USB privacy class appears in Apple's lists.
- Whether a CLI read inside `~/Library/CloudStorage/OneDrive-Personal` prompts, and where it then shows
  up. Directory listing is verified to work without a grant.
- `Privacy_LocalNetwork` as a pane anchor: absent from Apple's 26.6 pane metadata and from the macOS 26
  community URL list I used.
- Rex: whether `pam_tid` fails inside a Rex tab. The mechanism explains why it can; it is untested here.
- Notification authorization for Rex: no read-only CLI check exists as far as I could find.
- The exact `Disposition`/`Type` bit values in `sfltool dumpbtm` output come from forensic tool docs, not
  Apple; Apple's man page does not cover `dumpbtm` at all.

## 10. Sources used, once each

- Rex: [Server API](https://www.superlogical.com/rex/docs/reference/api#serverappleprivacy_status) ·
  [CLI `rex api`](https://www.superlogical.com/rex/docs/reference/cli#rex-api) ·
  [Mac Actions](https://www.superlogical.com/rex/docs/reference/mac-actions#action-client-permissions) ·
  [Privacy & Telemetry](https://www.superlogical.com/rex/docs/reference/privacy)
- Apple TCC: [Controlling app access to files](https://support.apple.com/guide/security/controlling-app-access-to-files-secddd1d86a6/web) ·
  [Platform Security](https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web) ·
  [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) ·
  [Privacy & Security pane](https://support.apple.com/guide/mac-help/change-privacy-security-settings-on-mac-mchl211c911f/mac) ·
  [Developer Tools pane](https://support.apple.com/guide/mac-help/control-ability-apps-run-software-meet-mchlc5fb7f9c/mac)
- Consent APIs: [AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions) ·
  [CGPreflightScreenCaptureAccess](https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess()) ·
  [IOHIDCheckAccess](https://developer.apple.com/documentation/iokit/3181573-iohidcheckaccess) ·
  [AVCaptureDevice.authorizationStatus](https://developer.apple.com/documentation/avfoundation/avcapturedevice/authorizationstatus(for:)) ·
  [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events) ·
  [NSFileProviderDomainUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsfileproviderdomainusagedescription)
- Background items: [Apple deployment guide](https://support.apple.com/guide/deployment/manage-login-items-background-tasks-mac-depdca572563/web) ·
  [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) ·
  [DumpBTM](https://github.com/objective-see/DumpBTM/) ·
  [macforensics BTM](https://www.macforensics.app/en/artifacts/login-items-btm) ·
  [eclecticlight.co](https://eclecticlight.co/2025/12/03/manage-login-and-background-items/)
- Tools: [peekaboo permissions](https://github.com/openclaw/Peekaboo/blob/main/docs/commands/permissions.md) ·
  [peekaboo.sh](https://peekaboo.sh/permissions.html) ·
  [Chromium pref_names.h](https://chromium.googlesource.com/chromium/src/+/main/chrome/common/pref_names.h) ·
  [chromium.org AppleScript](https://www.chromium.org/developers/applescript/) ·
  [Hex](https://github.com/anomalyco/hex/blob/main/docs/features/README.md) ·
  [pam_reattach](https://github.com/fabianishere/pam_reattach/) ·
  [WritingTools URL fix](https://github.com/theJayTea/WritingTools/pull/261) ·
  [macOS 26 settings URLs](https://github.com/ssbozy/macos-settings-urls)
