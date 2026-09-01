# Pugly

## Goal

A Smalltalk-style web app builder. App code is Scheme s-expressions interpreted at
runtime. Editing a component redefinition re-renders live instances immediately,
preserving state. The app is captured as a blob of Scheme code.

This prototype proves **one thing**: the live-edit loop. Everything else is deferred.

## Minimal flow (the only flow to build)

1. Load the builder. The editor is pre-seeded with a trivial `main` definition,
   already mounted and rendering in the preview.
2. Edit `main`; press Register; the preview updates.
3. Define a second component in the same buffer and call it from `main`.
4. Interact with it; state changes; DOM updates.
5. Edit a definition; re-register. Live instances re-render with new code and
   **existing state intact**.
6. Evaluate an arbitrary expression against the running app (REPL box).
7. Dump all definitions as Scheme text.

## Constraints

- Framework is a **library of procedures/macros**, not a DSL. App code is full Scheme.
- Components are called as ordinary procedures. The binding is a **stub** whose
  identity never changes; it reads the definition cell on every call, so app code
  can never capture a definition. Late binding is preserved without app-code
  ceremony.
- App state lives in an **external keyed store**, never owned by a component instance.
- App code gets no ambient capabilities: don't build ambient fetch or storage access.
- Fine-grained reactivity only. No VDOM, no diffing.
- Out of scope: SSR, hydration, assistant integration, fuel budgets, source spans,
  macro definition by app code, persistence, styling.

## Technology

- **One HTML file**, openable directly from disk. LIPS from a CDN via a classic
  `<script>` tag; no bundler, no npm, no ES modules (they fail under `file://`).
- **LIPS Scheme** (browser, JS-hosted interpreter). Direct JS/DOM interop, instant
  eval, no build step.
- Framework written in Scheme, running on LIPS. App code evaluated via host `eval`
  in a prepared environment.
- Keep LIPS-specific features confined to the FFI/DOM module so host coupling stays
  in one place.

### Load order

Framework source lives in `<script type="text/scheme">` blocks — an inert type, so
the browser ignores them. Shell JS reads their `textContent` in document order and
evaluates each through LIPS, then creates the app environment, then mounts `main`,
then wires the shell controls. Do not rely on automatic execution of script tags;
explicit ordering matters here and is worth the three lines.

The step-1 test harness lives in the same file, behind a flag, logging to the
console.

### Host constraints (verified — do not rediscover these)

- **Never use `guard` in the reactive core.** LIPS compiles `guard` to `try`, which
  always returns a Promise. One `guard` on the propagation path makes the whole
  update cycle asynchronous and permanently strands the `Updates`/`Effects` queues,
  so the *second* write silently does nothing. Error isolation must call a
  synchronous `try/catch` in the host shim.
- **Symbols stored in `define-record-type` fields come back broken** — `symbol?`
  returns false and `(eq? x x)` is false. Use integers for node kinds and strings
  for component names.
- **LIPS strings are boxed objects.** Assigning one to `textContent`/`innerHTML`
  throws "Cannot convert object to primitive value". Every string crossing into the
  DOM goes through a host shim that calls `String()`.
- **`append` clones its list arguments**, so object identity does not survive a
  list update. App code must compare by key, not with `eq?`.

### Known prototype gap

Host `eval` means no step budget, so `(let loop () (loop))` in app code freezes the
tab. Accept it; reload to recover.

## Design

Reactive core is Solid's track / mark / propagate algorithm (`STALE`/`PENDING`
two-colour marking, paired slot arrays, `Updates` drained before `Effects`).
Implement it as specified publicly. The deltas that matter here:

1. **Component definitions live in signals.** `(define-component! name proc)` writes
   to the cell and, on first use of that name, binds a stub procedure of the same
   name in the app environment. Calling the stub reads the cell (subscribing the
   caller), opens a child computation, and applies the definition to the arguments.
   A redefinition is an ordinary signal write: instances go `STALE`, propagation
   re-renders, `clean-node` disposes the old subtree. No hot-reload mechanism exists.

   *Forward references:* register components before first render. If a render hits
   an unbound name, catch it, create an empty cell and stub that renders a
   placeholder, and re-run — defining the component later then fixes the render by
   the same signal-write path.
2. **State is external.** Instances read/write the store by key. Code swaps therefore
   preserve state for free.
3. **The owner tree is the inspector.** Do not build a parallel scene graph.
4. **Per-effect error isolation.** An erroring effect is marked, rendered as a
   placeholder in place, and the queue keeps draining. Other effects stay live.

## Data structures

```
signal      : value, observers[], observer-slots[], equal?
computation : proc, sources[], source-slots[], state, owner, children[],
              cleanups[], error
```

`state` ∈ {`clean`, `stale`, `pending`}. Slot arrays are index back-pointers for
O(1) unlink (swap-remove).

Globals: `*listener*`, `*owner*`, `*updates*`, `*effects*`, `*batch-depth*`.
Use fluids/`parameterize`, not `set!`.

Registries, both plain hash tables:

```
*components* : symbol      -> signal holding a procedure
*store*      : key (list)  -> signal holding a value
```

`*store*` creates a signal lazily on first read with the supplied default, so a
re-render after redefinition finds the existing signal rather than resetting it.

Renderer holds real DOM nodes directly (LIPS interop). No handle table.

## Algorithms

**Mounting happens once, at load.** The framework calls
`(mount! preview-root (lambda () (main)))` on startup, before any app code is
registered — the forward-reference path supplies a placeholder stub for `main`
until the buffer defines it. There is no user-facing mount action, and the root
computation created here is the only thing that survives every redefinition.

**Render.** `mount!` creates a root computation. Calling a component
stub reads its cell (subscribing), opens a child computation, applies the definition
to the given arguments, and walks the returned SXML creating DOM nodes. A child that
is a procedure is a reactive hole: wrap it in an effect that writes into a dedicated
text node.

**Re-render on redefinition.** Falls out of propagation. The instance computation is
`STALE`, so `clean-node` runs its cleanups (removing its DOM subtree and disposing
owned children), then the procedure re-runs against the unchanged store.

**Markup is SXML**, written with quasiquote so dynamic parts arrive via unquote.
Interpreted at render time; no macro expansion needed for the prototype.

```
element   : (tag . children)
          | (tag (@ (name value) ...) . children)
child     : string | number
          | element
          | procedure          ; reactive hole -> own effect + text node
          | node record        ; result of a component call or (each ...)
          | list of children   ; fragment, spliced
attr value: string
          | procedure          ; `on-*` names bind a listener, others are reactive
```

`each` keys children by `key-proc` and reconciles by key on change: create new keys,
dispose missing ones, reorder survivors. Do not rebuild the list.

Reject any element whose tag is not a symbol, with a clear error — a stray unquote
turning a child into a list is the most likely app-code mistake.

## API surface for app code

```
(define-component! 'name (lambda (arg ...) sxml))
(name arg ...)                     ; -> node record, unquote into markup
(each items-thunk key-proc render-proc)  ; -> node record
(state key default)                ; -> getter procedure
(state-set! key value)
(memo thunk)                       ; -> getter procedure
(effect thunk)
(batch thunk)
```

## Example 1 — Counter (tests state survival across redefinition)

```scheme
(define-component! 'counter
  (lambda ()
    (let ((n (state '(counter n) 0)))
      `(div
        (span ,(lambda () (number->string (n))))
        (button (@ (on-click ,(lambda (ev) (state-set! '(counter n) (+ (n) 1)))))
                "+1")))))
```

Mount it, click to 5, then re-register with the span body changed to
`,(lambda () (string-append "count: " (number->string (n))))`.
**Pass:** the DOM updates and still shows 5.

## Example 2 — Todos (tests `each`, memos, composition, arbitrary logic)

```scheme
(define-component! 'todo-row
  (lambda (item)
    (let ((id (cdr (assq 'id item))))
      `(li
        (span ,(cdr (assq 'text item)))
        (button (@ (on-click
                    ,(lambda (ev)
                       (let ((items (state '(todos items) '())))
                         (state-set! '(todos items)
                                     (filter (lambda (x)
                                               (not (equal? (cdr (assq 'id x)) id)))
                                             (items)))))))
                "x")))))

(define-component! 'todos
  (lambda ()
    (let* ((items (state '(todos items) '()))
           (n     (memo (lambda () (length (items))))))
      `(div
        (p ,(lambda () (string-append (number->string (n)) " items")))
        (ul ,(each items
                   (lambda (item) (cdr (assq 'id item)))
                   (lambda (item) (todo-row item))))
        (button (@ (on-click
                    ,(lambda (ev)
                       (let ((id (length (items))))
                         (state-set! '(todos items)
                                     (append (items)
                                             (list (list (cons 'id id)
                                                         (cons 'text
                                                               (string-append
                                                                "task "
                                                                (number->string id)))))))))))
                "add")))))
```

**Pass:** adding and removing rows updates the count and the list. Redefining
`todo-row` alone re-renders every row and leaves the items intact. Redefining
`todos` preserves the items too.

## Builder shell

Plain HTML/CSS/JS, **not** built with the framework. The shell must keep working
when the framework is broken, which is most of the time during development.

```
┌─────────────────────────────────────────────┐
│ header                                      │
├──────────────────────┬──────────────────────┤
│                      │ preview              │
│ editor          50%  │                 75%  │
│                      ├──────────────────────┤
│                      │ inspector       25%  │
└──────────────────────┴──────────────────────┘
```

- **Header:** app name, `Dump` (writes the registry to the editor as Scheme text —
  it can diverge from the buffer if the REPL defines things), and a status line for
  the last register/eval result or error.
- **Editor:** one plain `<textarea>` holding all definitions, plus `Register`.
  Register reads every form in the buffer and evaluates it in the app environment.
  No syntax highlighting, no per-component files. Seeded at load with:

  ```scheme
  (define-component! 'main
    (lambda ()
      `(div "hello")))
  ```
- **Preview:** a single empty `<div>` used as the mount root, mounted once at
  startup. The app renders into the live document, so app styles and shell styles
  share a page — leave the shell unstyled enough that this doesn't matter yet.
- **Inspector:** two tabs. *Tree* renders the owner tree, refreshed on demand by a
  button, not reactively. *REPL* is an input plus scrollback, evaluating in the same
  environment as Register.

## Build order

1. Reactive core + a test harness with no DOM (signals, memos, effects, diamond case).
2. Renderer: SXML walk, reactive holes, attributes, listeners.
3. Component cells, stubs, and startup mount of `main`.
4. External store.
5. `each` with keyed reconciliation.
6. Builder shell: layout, editor, Register, Dump, REPL tab.
7. Per-effect error isolation.
8. Owner-tree inspector tab.
