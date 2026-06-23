# Handoff — zigbee2mqtt frontend gate + conditional homeui menu

Context for a fresh agent. Two related workstreams:
- **A.** z2m `.deb` exposes the z2m web frontend through homeui, gated by the homeui
  session (largely done, packaging-only — see commit).
- **B.** NEW: make a homeui custom-menu item show only when an integration is enabled,
  driven by MQTT (design accepted this session, **not yet implemented**).

> **HARD CONSTRAINT (user): do NOT `git commit` or push anything — in either repo —
> until the user has reviewed. No git mutations without explicit go-ahead.**

---

## Workstream A — z2m frontend behind the homeui gate

### Goal
Expose the z2m **web frontend** through homeui, gated by the homeui session — instead
of z2m's weak native `auth_token`. Mirrors wb-node-red packaging (nginx drop-in inside
the homeui server block + `auth_request` to `/auth/check`).

### State
- **Repo/branch:** `build-zigbee2mqtt` @ `feature/INT-622-zigbee2mqtt-frontend` (pushed).
- **Commit:** `b10e90b` *"Serve the zigbee2mqtt frontend behind the homeui session
  gate"* — read the commit message + diff rather than re-deriving. 9 files, package-only
  (`package/` nginx confs, custom-menu json, `wb-homeui-integration.sh`, after-install/
  after-remove hooks) + `configuration.yaml` (frontend on loopback + `base_url`) +
  `build.sh` (fpm hooks & file staging).
- **PR:** not opened.

### Final read-through this session (clean)
Re-read the whole branch diff: package-only, internally consistent, src/dst paths match
across `build.sh` / helper / after-remove. **No AI artifacts in the commit.** Only two
**untracked** files in the working tree, never staged:
- `HANDOFF.md` (this file — working doc, keep untracked, out of the PR);
- `.idea/` (PyCharm). **Recommended:** add `.idea/` to `.gitignore` (currently NOT
  ignored — only `result/`, `zigbee2mqtt/` are). Not done yet — user reviewing.

### Role gating — RESOLVED + HITM-verified
The gate requires `Required-User-Type: admin` (`package/nginx/wb-zigbee2mqtt.conf:27`),
delegated to homeui `/auth/check` (hierarchical: `admin > operator > user`). So **only
admin** reaches the frontend; `operator` and `user` are both blocked. User wanted to
block the `user` role — admin-only already does that (and more). User chose to **keep
admin-only** (not relax to operator). HITM: user confirmed on the controller that a
non-admin hitting the URL gets **Forbidden**. No code change needed.

### Edge cases analysed this session (theoretical, sourced)
- **No users configured (fresh/factory-reset controller):** homeui opens with admin
  rights **without login** by design; `/auth/check` returns 200 → the gate passes → z2m
  frontend is open **without login**, exactly as permissive as homeui itself. Source:
  https://wiki.wirenboard.com/wiki/Wiren_Board_Web_Interface . Not a bug in our gate —
  z2m security == homeui security.
- **z2m disabled (service stopped / `frontend.enabled:false` / `:8081` down):**
  - Menu tab **stays visible** — the custom-menu JSON is a static file, independent of
    service state.
  - By URL: non-admin → login redirect (gate runs before proxy); admin → raw **502 Bad
    Gateway** (proxy to dead `:8081`), no friendly page.
  - This 502 / always-visible-tab gap is what motivated Workstream B below.

### Decisions already made (don't relitigate)
- **fpm hook XOR.** `after_install` runs only on fresh install, `after_upgrade` only on
  upgrade. Placement was extracted into `package/wb-homeui-integration.sh`, invoked from
  **both** hooks. Do not fold back into one hook.
- **Correct repo.** Belongs in build-zigbee2mqtt (packages z2m incl. the frontend), NOT
  the converters `wb-mqtt-zigbee` / `wb-zigbee2mqtt` (pure MQTT→`/devices/` bridges).
- **Per-arch + vendored node_modules stays.** z2m has a native dep
  (`@serialport/bindings-cpp`); the wb-node-red noarch/offline packaging is N/A here.

### Open TODO (Workstream A)
1. **Ticket/branch name.** `INT-622` likely the wrong ticket — rename once the real id
   is known. Cosmetic.
2. **Version bump for delivery.** Version = `<z2m-tag>` + `WB_REVISION` (`-wb101`, a
   Jenkins param). To ship over the same z2m 2.10.0, build with `WB_REVISION=-wb102`.
3. **Upgrade path leaves frontend off for existing installs.** `after-upgrade.sh`
   restores the user's old `configuration.yaml` (no `frontend:` section) → existing
   installs keep the frontend disabled on upgrade (gate + menu still placed). Only fresh
   installs get the frontend on. Confirm intended or add a migration.
4. **Clean-install test (main untested path).** Build the `.deb` with the new hooks and
   install from scratch to confirm `after_install` → `wb-homeui-integration.sh` places
   gate + menu and the frontend comes up gated. Live controller files were placed by
   hand; a clean `.deb` install has NOT been done.
5. **Packaging-procedure unification (discussion only).** Unify the *procedure with a
   branch* (pure-JS → noarch/tarball/offline; native → per-arch/pnpm), not one schema.
   Right home: an ADR + maybe the `package-bootstrap` skill (ships from
   `wirenboard/wb-agent-tools` marketplace → a real change is a PR there). Nothing written.

---

## Workstream B — conditional menu visibility by MQTT (NEW — design accepted, NOT built)

### Goal
A homeui custom-menu item appears only when its integration is enabled, driven by MQTT.
**Reusable across integrations** (not z2m-specific). z2m is just the first consumer.

### Decisions taken this session (via brainstorming)
1. **Granularity = per page load.** No live reactivity. Visibility decided when the menu
   is built/served; toggling the integration shows up after F5/navigation. (homeui
   already fetches `/ui/menu` once per page load and caches it — `ui-store.ts`
   `#additionalItems`.)
2. **Match = `topic == equals`.** Compare the topic's **retained** payload (string) to a
   configured value.
3. **Evaluate on the homeui BACKEND**, not the frontend (avoids the frontend
   build-before-value race; frontend stays unchanged).

### Design (to be turned into a plan + spec — not written yet)
- **Schema:** add an optional field to a custom-menu item:
  `"visibleWhen": { "topic": "<mqtt topic>", "equals": "<string>" }`.
  Absent → always visible (back-compat, same spirit as the existing `requiredRole`).
- **Backend** (`homeui` `backend/wb/homeui_backend/main.py`: `custom_menu_handler` /
  `add_menu_items`):
  - Collect all `visibleWhen.topic`; open **one** MQTT connection per `/ui/menu` request
    (reuse the `mqtt_client(name)` pattern at `security.py:19`); subscribe to all topics;
    gather retained payloads in a short timeout window (retained arrive on subscribe).
  - Item visible iff retained payload `== equals`.
  - **Fail modes:** broker unreachable → **fail-open** (show all, log warning, don't hide
    a working integration on a backend hiccup); connected but no retained for the topic
    (genuinely absent) → **hide**; value ≠ equals → hide.
  - Strip `visibleWhen` from the JSON returned to the frontend; drop failed items and
    prune emptied containers (cf. frontend `filterMenuItems` in `menu-items.ts`).
  - Frontend: **no change**.
- **z2m signal (build-zigbee2mqtt side, separate change):**
  - *Recommended:* package publishes a dedicated **retained** topic with a clean value
    (`1`/`0`) via systemd `ExecStartPost`/`ExecStopPost` on `zigbee2mqtt.service`; menu
    config `visibleWhen: { topic: "<that topic>", equals: "1" }`. Decoupled from z2m's
    internal topics; covers the deliberate enable/disable "toggle" case.
  - *Alternative:* reuse `zigbee2mqtt/bridge/state` (has LWT, catches crashes too) but
    payload is JSON `{"state":"online"}` → matching is messier. Decide at packaging time.
- **Tests** (homeui backend, `backend/tests/main_test.py` exists): condition pass → kept;
  fail / topic absent → removed; broker error → kept (fail-open); container emptied by
  condition → pruned; `visibleWhen` not present in the served JSON.
- **Out of scope (YAGNI):** live reactivity; operators beyond `equals`; multiple
  conditions per item.
- **Risk to validate in the plan:** a blocking MQTT read inside the request handler —
  check the backend server's concurrency model so it can't stall other requests (batch
  all topic reads into the single connection; bounded timeout).

### homeui repo facts (corrects the old "uncommitted" note)
- Repo: `/Users/smintank/PycharmProjects/homeui`, branch
  `feature/INT-622-external-menu-links` (also on `origin`).
- External-links work is **committed** on that branch: `d59bef78` "Support external links
  in the navigation menu", `50eae59d` "Honour an external return target after login",
  `f6ed1b5e` "Harden externalReturn open-redirect guard", `778ecb4d` "Drop
  returnState=undefined…". There are **also uncommitted WIP** changes in the working tree:
  `frontend/src/components/navigation/components/menu-item/menu-item.tsx`,
  `frontend/src/stores/ui/{types.ts,menu-items.ts,ui-store.ts,ui-store.test.ts}`.
- `CustomMenuItem` (`stores/ui/types.ts`) already has `isExternal`, `openInNewTab`, and
  `requiredRole` (hierarchical role gate), evaluated in `menu-items.ts`
  `toMenuItemInstance` → `isShow`. The new `visibleWhen` follows the same **declarative**
  pattern, but is evaluated **backend-side** (the others are frontend-side).
- `/ui/menu` is served by the backend `custom_menu_handler` (`main.py:498`), reading
  `*.json` from `CUSTOM_MENU_FOLDER = /usr/share/wb-mqtt-homeui/custom-menu` (`main.py:42`).

---

## Controllers touched (clean up if desired)
- **a5fq6odf / 192.168.1.103** (WB8, Zigbee module on MOD4): z2m + wb-mqtt-zigbee
  installed & running; frontend gated and working; homeui `/var/www` replaced with a
  build carrying `externalReturn`/`openInNewTab` (stock backup at
  `/tmp/www-stock-bak-*.tar.gz`); a fresh empty Zigbee network was created.
- **AAT3D5FW / 192.168.1.158** (no module): z2m installed but stopped/disabled.

## Suggested skills for the next session
- `superpowers:writing-plans` — turn the accepted Workstream B design into an
  implementation plan (this was the brainstorm's next step).
- `wb-development:plan-feature` / `wb-development:coder` — plan & implement the homeui
  backend change + the z2m packaging signal.
- `wb-webui-test` — test the homeui menu behaviour.
- `wb-git:pr-author` — open/manage PRs (only after the user approves committing).
- `wb-controller-ops` — build/install the `.deb` for the clean-install test (A.4), or
  revert controller-side changes.
- `wb-plc:wiren-board` + `wb-plc:wb-zigbee` — controller access & Zigbee specifics.

## Key references
- Commit `b10e90b` on `feature/INT-622-zigbee2mqtt-frontend` (this repo) — Workstream A.
- Pattern source: `wb-node-red` repo — `nginx/wb-node-red.conf`, `debian/postinst`.
- homeui: `/Users/smintank/PycharmProjects/homeui` @ `feature/INT-622-external-menu-links`.
