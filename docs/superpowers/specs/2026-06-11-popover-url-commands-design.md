# Popover URL Commands Design

**Goal:** Add `pixelwatch://show` and `pixelwatch://hide` so external automation can open and close the menu-bar popover, with those requests flowing through the app's event bus.

## Scope

This change adds two new URL actions:

- `pixelwatch://show`
- `pixelwatch://hide`

They are distinct from watcher-targeted URL actions (`arm`, `pause`, `delete`) and do not take an `id` query parameter.

## Design

### Command parsing

`URLCommandParser` will accept `show` and `hide` as valid actions and return dedicated command values for them.

Watcher-targeted actions keep their current parsing contract:

- action must be one of `arm`, `pause`, `delete`
- `id` query parameter must exist and decode as a UUID

UI actions do not require an `id`.

### Event bus integration

Popover visibility requests will be represented as new `PixelWatchEvent` cases:

- `popoverShowRequested`
- `popoverHideRequested`

These are transient UI-control events. They do not represent persisted watcher state.

The app delegate remains the AppKit owner of the actual `NSPopover`, but it reacts to bus events rather than treating URL commands as a direct imperative control surface.

### URL handling

When the app receives `pixelwatch://show` or `pixelwatch://hide`, it will publish the corresponding popover event onto `EventBus`.

Existing watcher URL actions keep their current behavior.

### UI reaction

The app delegate's event-consumption path will react to the new bus events by calling explicit `showPopover()` and `hidePopover()` helpers.

Both operations are idempotent:

- `show` while already shown does nothing
- `hide` while already hidden does nothing

`toggle` is intentionally not added. Automation should target explicit state.

## Testing

Add parser tests covering:

- `pixelwatch://show`
- `pixelwatch://hide`
- existing watcher commands still parse correctly
- malformed watcher commands still fail

Add event-codable tests covering:

- encode/decode round-trip for `popoverShowRequested`
- encode/decode round-trip for `popoverHideRequested`
