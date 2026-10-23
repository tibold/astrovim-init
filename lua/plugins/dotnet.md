# .NET: known issues

C# runs through nvim-dotnet, a port of roslyn.nvim with a project-system
service that loads solutions from a cache. `use_nvim_dotnet` at the top of
`dotnet.lua` switches back to roslyn.nvim; both stay installed.

The issues below were found on Windows with roslyn.nvim and the
`roslyn-language-server` global tool, and not reported upstream. nvim-dotnet
fixes the freezes and the Razor wait itself, so their workarounds in
`dotnet.lua` apply to roslyn.nvim only.

## nvim-dotnet's service, from the clone

- **What happens:** the service is not on nuget.org yet, so the plugin cannot
  install it. Both the plugin and the service come from the clone named in
  `dotnet.lua`; `server.path` points at the service's Debug build there.
- **Rebuilding** after a pull, with every editor that has C# open closed (a
  running service holds the dll):

  ```
  dotnet build server/src/ArchPillar.Nvim.Dotnet.Service -c Debug -nodeReuse:false --disable-build-servers
  ```

  Without a build, `dotnet.lua` switches to dev mode, which builds it in the
  background; that session's first client uses Roslyn's own loader.
- **Its own daemon pipe** (`nvim-dotnet`): a daemon that roslyn.nvim started
  has no broker-reset extension, and sharing it made each target restart
  without the daemon.

## Neovim freezes while files in the solution change

- **Symptom:** the editor locks up during a build, a checkout or a burst of
  edits from outside it; writing 300 files into an `obj/` folder stalled it for
  3s, one stall 622ms. An editor without Roslyn did not stall at all.
- **Cause:** when Neovim does Roslyn's file watching, a large solution's
  projects register ~3,700 watchers, 340 of them on its `src/` folder itself.
  Neovim starts one recursive OS watcher per watcher and runs each one's
  callback on the main loop, so every change under `src/` costs ~350.
- **Workaround:** `filewatching = "roslyn"`: Neovim does not offer file
  watching, so Roslyn watches in its own process. Neovim's watching is said to
  catch changes Roslyn's misses; if a file made outside the editor goes unseen
  until opened, this is why.

Found under easy-dotnet.nvim, which hands the watching to Neovim on Windows and
macOS; roslyn.nvim's default (`"auto"`) does the same. nvim-dotnet never uses
Neovim's watcher.

## Typing is held up when a Razor file is first opened

- **Symptom:** opening the first `.razor` file of a session freezes the editor
  for a second up to several seconds; measured 633ms one time, longer while
  Roslyn loads a solution from a cold cache.
- **Cause:** Roslyn asks the `html` server about a Razor file's markup through
  the client (folding ranges, colours, hover…). roslyn.nvim's
  `documentManager.getDocument` first waits, with `vim.wait(5000)`, for that
  server to attach to the file's hidden `__virtual.html` copy; `vim.wait` keeps
  timers running but holds up keys. The server is Node and starts slowly on
  Windows, so the first questions each wait for it, up to 5s apiece.
- **Workaround:** `getDocument` is wrapped to wait by yielding first: Neovim
  handles server requests in a coroutine, so the plugin's own wait then finds
  its condition met and returns at once. nvim-dotnet waits without blocking.

## Which Roslyn runs, and updating it

- **What happens:** both plugins run Mason's `roslyn-language-server` when
  there is one, else the first on the PATH, which is the global tool here.
  For roslyn.nvim, `dotnet.lua` names the launcher by full path, since
  Neovim searched the PATH each time it considered starting the server;
  nvim-dotnet searches once per session.
- **Razor needs** `5.12.0-1.26453.19` or later (roslyn.nvim's README).
- **Updating:** from the Azure DevOps feed, with an explicit `--version`. A
  plain `--prerelease` update from the feed picks a `-test` build, since
  `1-test` sorts above `1`. Close every editor with C# open first: on Windows
  the running server holds the tool's files open, and the update fails.

  ```
  dotnet tool update -g roslyn-language-server --version <version> --source https://pkgs.dev.azure.com/azure-public/vside/_packaging/vs-impl/nuget/v3/index.json
  ```

## Unrelated, but it looked like one: Razor markup in the work solution

Razor markup had no answers because Roslyn could not load the project: the
repo's `StaticAssets.targets` errors on stale, gitignored `.razor.css` files
whose `.scss` was deleted. Deleting those fixed it; the rule itself is a hard
`<Error>` in IDE builds too.
