-- Kişisel Neovim kurulumu
--
-- Odak: dosya gezgini, Codex oturumu ve Codex'in yaptığı değişiklikleri
-- güvenli biçimde inceleyebilmek.

vim.g.mapleader = " "
vim.g.maplocalleader = " "
vim.g.have_nerd_font = true

-- nvim-tree netrw'nin yerini alıyor.
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

vim.opt.number = true
-- Absolute numbers are easier to follow when the editor is used mostly with
-- the mouse. Relative numbers made the left gutter look as if it was jumping
-- while the cursor moved.
vim.opt.relativenumber = false
vim.opt.signcolumn = "yes"
vim.opt.termguicolors = true
vim.opt.mouse = "a"
-- A click already focuses a split. Pointer-driven focus races terminal mouse
-- release events and can swallow the first click on the destination pane.
vim.opt.mousefocus = false
vim.opt.mousemodel = "popup_setpos"
vim.opt.mousescroll = "ver:5,hor:2"
vim.opt.clipboard = "unnamedplus"
vim.opt.updatetime = 250
vim.opt.timeoutlen = 400
vim.opt.scrolloff = 6
vim.opt.sidescrolloff = 8
vim.opt.cursorline = true
vim.opt.cursorlineopt = "number,screenline"
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.expandtab = true
vim.opt.shiftwidth = 2
vim.opt.tabstop = 2
vim.opt.autoread = true

-- Buffer/dosya başına kalıcı undo; editör kapansa bile değişiklik geçmişi
-- korunur ve yanlışlıkla kapatılan değişiklikler geri alınabilir.
vim.opt.undofile = true
vim.opt.undodir = vim.fn.stdpath("state") .. "/undo//"

-- Codex (veya başka bir terminal süreci) dosyayı disk üzerinde değiştirdiğinde,
-- odak geri geldiğinde mevcut, kaydedilmemiş olmayan buffer'ı yeniden kontrol et.
-- Neovim, yerel unsaved değişiklikleri otomatik olarak ezmez; bu durumda uyarı
-- gösterir ve karar editöre bırakılır.
local refresh_group = vim.api.nvim_create_augroup("CodexExternalChanges", { clear = true })
vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold" }, {
  group = refresh_group,
  callback = function()
    if vim.bo.buftype == "" then
      pcall(vim.cmd, "checktime")
    end
  end,
})
vim.api.nvim_create_autocmd("FileChangedShellPost", {
  group = refresh_group,
  callback = function()
    if package.loaded["gitsigns"] then
      pcall(function()
        require("gitsigns").refresh()
      end)
    end
  end,
})

-- lazy.nvim'i ilk açılışta kur.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
local uv = vim.uv or vim.loop
if not uv.fs_stat(lazypath) then
  local output = vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
  if vim.v.shell_error ~= 0 then
    error("lazy.nvim kurulamadı:\n" .. output)
  end
end
vim.opt.rtp:prepend(lazypath)

-- On this macOS image `/usr/bin/clang` is an arm64e xcrun shim whose
-- Xcode-linked libxcrun cannot be loaded by arm64 Neovim.  The standalone
-- CommandLineTools compiler is native arm64; point parser/build jobs at it
-- and its SDK without overriding a user-provided compiler.
local clt_clang = "/Library/Developer/CommandLineTools/usr/bin/clang"
local clt_sdk = "/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk"
if vim.fn.executable(clt_clang) == 1 and vim.uv.fs_stat(clt_sdk) then
  if vim.env.CC == nil or vim.env.CC == "" then
    vim.env.CC = clt_clang
  end
  if vim.env.SDKROOT == nil or vim.env.SDKROOT == "" then
    vim.env.SDKROOT = clt_sdk
  end
end

local function refresh_current_buffer()
  if vim.bo.buftype == "" then
    pcall(vim.cmd, "checktime")
  end
  if package.loaded["gitsigns"] then
    pcall(function()
      require("gitsigns").refresh()
    end)
  end
end

-- Forward declaration: the YOLO wrapper below opens Diffview after close_tab.
local open_codex_diff
-- These helpers are declared before the codex.nvim wrapper because lazy.nvim
-- may configure codex.nvim before the later layout helpers are reached.
local ensure_center_editor_window
local open_edited_files_in_center
local collapse_pending_codex_diff

-- Codex CLI'nin YOLO ayarı ile codex.nvim'in openDiff onayı birbirinden
-- bağımsızdır.  Bu küçük köprü, yalnızca gerçekten YOLO/full-access açıkken
-- bekleyen diff'i otomatik kabul eder; diff penceresi kapatıldığında da Git
-- diff'ini merkez editörde görünür bırakır.
local function codex_yolo_enabled()
  if vim.g.codex_yolo_diff ~= nil then
    return vim.g.codex_yolo_diff == true
  end

  local env_override = vim.env.CODEX_NEOVIM_AUTO_ACCEPT_DIFF
  if env_override and env_override ~= "" then
    return vim.tbl_contains({ "1", "true", "yes", "on" }, env_override:lower())
  end

  local config_path = vim.fn.expand("~/.codex/config.toml")
  local ok, lines = pcall(vim.fn.readfile, config_path)
  if not ok or type(lines) ~= "table" then
    return false
  end

  local approval_policy
  local sandbox_mode
  for _, line in ipairs(lines) do
    -- Codex writes TOML basic strings with double quotes.  Keep support for
    -- literal strings too, but do not put both quote types in one Lua
    -- pattern character class: in Lua patterns that turns the backslash into
    -- a literal character and silently prevents a match.
    approval_policy = approval_policy
      or line:match('^%s*approval_policy%s*=%s*"([^"]+)"')
      or line:match("^%s*approval_policy%s*=%s*'([^']+)'")
    sandbox_mode = sandbox_mode
      or line:match('^%s*sandbox_mode%s*=%s*"([^"]+)"')
      or line:match("^%s*sandbox_mode%s*=%s*'([^']+)'")
  end

  return approval_policy == "never" and sandbox_mode == "danger-full-access"
end

-- CodeCompanion keeps its own per-chat approval state.  Mirror the global
-- Codex mode into that cache without weakening tools which explicitly opt out
-- of YOLO (for example `run_command` and `delete_file`).
local function set_codecompanion_yolo(bufnr, enabled)
  if type(bufnr) ~= "number" or bufnr <= 0 then
    return
  end
  local ok, approvals = pcall(require, "codecompanion.interactions.chat.tools.approvals")
  if not ok or type(approvals) ~= "table" or type(approvals.is_approved) ~= "function" then
    return
  end
  if approvals:is_approved(bufnr, {}) ~= enabled then
    approvals:toggle_yolo_mode(bufnr)
  end
end

local function sync_codecompanion_yolo_buffers()
  if not codex_yolo_enabled() then
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "codecompanion" then
        set_codecompanion_yolo(bufnr, false)
      end
    end
    return
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "codecompanion" then
      set_codecompanion_yolo(bufnr, true)
    end
  end
end

local function install_codex_yolo_diff_wrapper()
  local ok, diff = pcall(require, "codex.diff")
  if not ok or type(diff) ~= "table" or diff._codex_yolo_wrapper_installed then
    return
  end

  local original_setup = diff._setup_blocking_diff
  local original_close = diff.close_diff_by_tab_name
  if type(original_setup) ~= "function" or type(original_close) ~= "function" then
    vim.notify("codex.nvim diff API değişti; YOLO diff köprüsü kurulamadı", vim.log.levels.WARN)
    return
  end

  diff._setup_blocking_diff = function(params, resolution_callback)
    -- codex.nvim normally picks the first non-terminal window.  In our
    -- three-pane layout that can be nvim-tree, so preload the target file in
    -- the real centre editor before the plugin chooses its diff window.
    if type(params) == "table" and type(params.old_file_path) == "string"
        and params.old_file_path ~= "" and open_edited_files_in_center then
      local old_path = vim.fn.fnamemodify(params.old_file_path, ":p")
      if vim.fn.filereadable(old_path) == 1 then
        open_edited_files_in_center({ old_path })
        local bufnr = vim.fn.bufnr(old_path)
        if bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_call(bufnr, function()
            pcall(vim.cmd, "checktime")
          end)
        end
      end
    end
    local result = original_setup(params, resolution_callback)
    -- codex.nvim's native setup creates an old/new vimdiff pair.  Collapse it
    -- immediately so the user sees one centre tab with mini.diff's inline
    -- red/green overlay instead of the duplicate side-by-side layout.
    collapse_pending_codex_diff(diff, params)
    if codex_yolo_enabled() then
      vim.schedule(function()
        local active = diff._get_active_diffs and diff._get_active_diffs() or {}
        local state = active[params.tab_name]
        if state and state.status == "pending" and state.new_buffer then
          diff._resolve_diff_as_saved(params.tab_name, state.new_buffer)
        end
      end)
    end
    return result
  end

  diff.close_diff_by_tab_name = function(tab_name)
    local active = diff._get_active_diffs and diff._get_active_diffs() or {}
    local state = active[tab_name]
    local was_saved = state and state.status == "saved"
    local edited_path = state and state.old_file_path
    local result = original_close(tab_name)
    if result and was_saved then
      -- close_tab, Codex'in dosyayı diske yazmasından sonra gelir.  Reload ve
      -- Diffview açılışı arasında küçük bir pay bırakıyoruz.
      vim.defer_fn(function()
        open_codex_diff(edited_path)
      end, 500)
    end
    return result
  end

  diff._codex_yolo_wrapper_installed = true
end

vim.api.nvim_create_user_command("CodexYoloDiff", function(opts)
  local value = vim.trim(opts.args or ""):lower()
  if value == "" or value == "toggle" then
    vim.g.codex_yolo_diff = not codex_yolo_enabled()
  elseif value == "on" or value == "true" or value == "1" then
    vim.g.codex_yolo_diff = true
  elseif value == "off" or value == "false" or value == "0" then
    vim.g.codex_yolo_diff = false
  else
    vim.notify("Kullanım: :CodexYoloDiff [on|off|toggle]", vim.log.levels.ERROR)
    return
  end
  vim.notify("Codex diff YOLO otomatik kabul: " .. (codex_yolo_enabled() and "açık" or "kapalı"))
  sync_codecompanion_yolo_buffers()
end, {
  nargs = "?",
  complete = function()
    return { "on", "off", "toggle" }
  end,
  desc = "Codex diff onayını YOLO modunda otomatik kabul et",
})


-- Codex runs as a child process in an embedded Neovim terminal.  It asks its
-- terminal for OSC 10/11 (default foreground/background) during startup; a
-- PTY hosted by Neovim does not have the outer terminal emulator around to answer those
-- requests, so the TUI otherwise falls back to a fixed palette.  Answer the
-- query from the active Neovim `Normal` highlight so a newly opened Codex
-- composer uses the same light/dark background as the selected editor theme.
local function codex_terminal_buffer(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.b[bufnr].codex_agent_id ~= nil then
    return true
  end
  if vim.b[bufnr].codex_terminal == true then
    return true
  end
  local ok, buffer = pcall(require, "codex.terminal.buffer")
  local result = ok
    and type(buffer) == "table"
    and type(buffer.is_codex_terminal_buffer) == "function"
    and buffer.is_codex_terminal_buffer(bufnr)
  return result
end

-- A mouse click can focus an already-visible terminal window while leaving
-- Neovim in terminal-normal mode. Snacks' `auto_insert` hook only covers
-- `BufEnter`, so restore terminal input on `WinEnter` as well. Do not inject
-- `<C-\\><C-n>` from `WinLeave`/`BufLeave`: doing that while Neovim is
-- dispatching the mouse gesture can swallow the first click when leaving
-- Codex for the tree or centre editor.
local codex_input_focus_group = vim.api.nvim_create_augroup("PersonalNvimCodexInputFocus", { clear = true })

-- Neovim only follows a terminal's cursor while that terminal is in focus.
-- Codex keeps streaming output in the right-hand pane after focus moves to
-- the tree/editor, so the viewport can remain several pages above the
-- composer.  Track Codex terminal buffer updates and keep every visible
-- Codex window pinned to the newest terminal row.  This is deliberately
-- debounced: a single response can emit hundreds of on_bytes notifications.
local codex_scroll_states = {}

local function scroll_codex_terminal_to_bottom(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not codex_terminal_buffer(bufnr) then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count < 1 then
    return
  end

  local state = codex_scroll_states[bufnr]
  if not state then
    return
  end
  -- Updating an unfocused terminal window's cursor forces a redraw of that
  -- pane while Codex is streaming.  The old implementation did this for
  -- every output batch, which made the right-hand Codex surface visibly
  -- flicker whenever the user clicked the centre editor.  Keep a pending
  -- marker and apply the scroll when the Codex window receives focus.  A
  -- quiet-period flush below also performs one catch-up move after a response
  -- settles, so the composer remains discoverable without a streaming blink.
  local current_win = vim.api.nvim_get_current_win()
  local focused_codex_window = false
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid)
        and vim.api.nvim_win_get_buf(winid) == bufnr
        and winid == current_win then
      focused_codex_window = true
      break
    end
  end
  -- A quiet background flush is allowed to move the viewport once after a
  -- response settles.  During the stream itself we leave the terminal
  -- completely untouched, which prevents the visible blink caused by a
  -- cursor move every few milliseconds.
  local allow_background_flush = state.background_flush == true
  if not focused_codex_window and not allow_background_flush then
    state.pending = true
    state.last_line_count = nil
    state.force = false
    return
  end
  -- Do not move the terminal cursor/redraw on every byte while another pane
  -- is focused.  This was the source of the visible Codex flicker.  A line
  -- count change (or an explicit focus request) is sufficient to pin the
  -- viewport again.
  local force = state.force == true
  if not force and state.last_line_count == line_count then
    return
  end

  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      local ok, visible_buf = pcall(vim.api.nvim_win_get_buf, winid)
      if ok and visible_buf == bufnr then
        -- A zero scrolloff lets the final prompt row use the full terminal
        -- height.  Setting the terminal buffer cursor is safe while another
        -- pane is focused (or a quiet flush is explicitly due) and makes
        -- Neovim redraw the viewport at the bottom.
        pcall(function()
          vim.wo[winid].scrolloff = 0
          vim.wo[winid].cursorline = false
          vim.wo[winid].cursorcolumn = false
          local cursor = vim.api.nvim_win_get_cursor(winid)
          if force or cursor[1] ~= line_count then
            vim.api.nvim_win_set_cursor(winid, { line_count, 0 })
          end
        end)
      end
    end
  end
  state.last_line_count = line_count
  state.force = false
  state.pending = false
  state.background_flush = false
end

local function schedule_codex_terminal_bottom(bufnr, delay, background_flush)
  local state = codex_scroll_states[bufnr]
  if not state then
    return
  end
  if delay == 0 then
    -- A focus request must not wait behind a quiet-period timer scheduled
    -- while the user was working in another pane.
    if state.timer then
      pcall(state.timer.stop, state.timer)
      pcall(state.timer.close, state.timer)
      state.timer = nil
    end
    state.force = true
    state.background_flush = false
  elseif background_flush then
    state.background_flush = true
    -- Restart the quiet-period timer for every output batch.  A long turn
    -- therefore produces no cursor movement until Codex has actually gone
    -- quiet for the requested interval.
    if state.timer then
      pcall(state.timer.stop, state.timer)
      pcall(state.timer.close, state.timer)
      state.timer = nil
    end
  end
  if state.timer then
    return
  end

  state.timer = vim.defer_fn(function()
    state.timer = nil
    scroll_codex_terminal_to_bottom(bufnr)
  end, delay or 120)
end

local function attach_codex_terminal_scroll(bufnr, attempt)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local state = codex_scroll_states[bufnr]
  if state and state.attached then
    schedule_codex_terminal_bottom(bufnr, 0)
    return
  end

  -- codex.nvim marks the buffer immediately after Snacks creates its PTY.
  -- TermOpen can therefore run a few milliseconds too early; retry briefly
  -- instead of attaching a generic shell terminal by mistake.
  if not codex_terminal_buffer(bufnr) then
    local next_attempt = (attempt or 0) + 1
    if next_attempt <= 20 then
      vim.defer_fn(function()
        attach_codex_terminal_scroll(bufnr, next_attempt)
      end, 75)
    end
    return
  end

  state = state or { attached = false }
  state.attached = true
  codex_scroll_states[bufnr] = state
  pcall(function()
    -- Keep enough scrollback for a long Codex turn while avoiding the very
    -- large default history that can make redraws expensive.
    vim.bo[bufnr].scrollback = math.max(10000, vim.bo[bufnr].scrollback or 0)
  end)

  local attached = vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      local state = codex_scroll_states[bufnr]
      -- Never move the background terminal cursor for every output batch while
      -- another pane owns focus.  A quiet-period timer below performs one
      -- catch-up scroll after the stream settles (or immediately on WinEnter).
      local current_win = vim.api.nvim_get_current_win()
      local codex_focused = false
      for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(winid)
            and vim.api.nvim_win_get_buf(winid) == bufnr
            and winid == current_win then
          codex_focused = true
          break
        end
      end
      if not codex_focused then
        if state then
          state.pending = true
          state.last_line_count = nil
        end
        -- Keep the input discoverable without redrawing the Codex pane while
        -- every token is arriving.  Resetting this quiet-period timer on each
        -- batch means a long response gets one catch-up scroll, not hundreds
        -- of cursor updates.
        schedule_codex_terminal_bottom(bufnr, 450, true)
        return
      end
      schedule_codex_terminal_bottom(bufnr)
    end,
    on_detach = function()
      local current = codex_scroll_states[bufnr]
      if current and current.timer then
        pcall(current.timer.stop, current.timer)
        pcall(current.timer.close, current.timer)
      end
      codex_scroll_states[bufnr] = nil
    end,
  })
  if not attached then
    state.attached = false
    return
  end

  schedule_codex_terminal_bottom(bufnr, 0)
end

local function codex_focus_window(winid)
  if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  if not codex_terminal_buffer(bufnr) then
    return
  end
  attach_codex_terminal_scroll(bufnr)

  vim.schedule(function()
    if not vim.api.nvim_win_is_valid(winid) or vim.api.nvim_get_current_win() ~= winid then
      return
    end
    local mode = vim.api.nvim_get_mode().mode
    -- Normal mode in a terminal buffer is reported as `nt`; `n` is used by
    -- older Neovim versions.  Do not disturb an already-active `t` mode.
    if mode == "n" or mode == "nt" then
      pcall(vim.cmd, "startinsert")
    end
  end)
end

vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "WinEnter", "TermOpen" }, {
  group = codex_input_focus_group,
  callback = function()
    local winid = vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_win_get_buf(winid)
    -- TermOpen fires before codex.nvim marks the freshly-created Snacks
    -- buffer.  Start the short retry loop for every terminal buffer so the
    -- marker race cannot leave the scroll follower unattached.
    if vim.bo[bufnr].buftype == "terminal" then
      attach_codex_terminal_scroll(bufnr)
    end
    codex_focus_window(winid)
  end,
})

-- CodeCompanion's reusable prompt has the same focus edge case: opening an
-- existing `codecompanion_input` float can emit only WinEnter, leaving it in
-- Normal mode after a mouse click.  Keep this separate from Codex terminal
-- handling so chat navigation and regular terminal buffers are unaffected.
local function codecompanion_input_window(winid)
  if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  return vim.bo[bufnr].filetype == "codecompanion_input"
end

local function focus_codecompanion_input(winid)
  if not codecompanion_input_window(winid) then
    return
  end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  if not vim.b[bufnr].personal_codecompanion_mouse_focus then
    vim.b[bufnr].personal_codecompanion_mouse_focus = true
    local enter_input = function()
      local current_win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_is_valid(current_win)
          and vim.api.nvim_win_get_buf(current_win) == bufnr then
        pcall(vim.cmd, "startinsert")
      end
    end
    for _, mouse_event in ipairs({ "<LeftMouse>", "<LeftRelease>" }) do
      vim.keymap.set("n", mouse_event, enter_input, {
        buffer = bufnr,
        silent = true,
        nowait = true,
        noremap = true,
        desc = "CodeCompanion input alanına tıklayınca yazma moduna geç",
      })
    end
  end

  vim.schedule(function()
    if not vim.api.nvim_win_is_valid(winid) or vim.api.nvim_get_current_win() ~= winid then
      return
    end
    local mode = vim.api.nvim_get_mode().mode
    if mode == "n" or mode == "nt" then
      pcall(vim.cmd, "startinsert")
    end
  end)
end

vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "WinEnter", "FileType" }, {
  group = codex_input_focus_group,
  pattern = "*",
  callback = function()
    focus_codecompanion_input(vim.api.nvim_get_current_win())
  end,
})

local function color_from_highlight(name, fallback)
  local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and type(value) == "table" and type(value.bg) == "number" then
    return value.bg
  end
  return fallback
end

local function rgb_components(color)
  if type(color) ~= "number" then
    return nil
  end
  local red = math.floor(color / 65536) % 256
  local green = math.floor(color / 256) % 256
  local blue = color % 256
  return red, green, blue
end

local function osc_rgb_response(slot, color)
  local red, green, blue = rgb_components(color)
  if not red then
    return nil
  end
  -- OSC rgb components are conventionally sent as 16-bit hex values. 257
  -- expands an 8-bit Neovim color component without changing its value.
  return string.format(
    "\027]%d;rgb:%04x/%04x/%04x\027\\",
    slot,
    red * 257,
    green * 257,
    blue * 257
  )
end

local function current_editor_colors()
  local normal = color_from_highlight("Normal", nil)
  local normal_float = color_from_highlight("NormalFloat", normal)
  local foreground
  local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
  if ok and type(value) == "table" and type(value.fg) == "number" then
    foreground = value.fg
  end
  return foreground, normal_float
end

local function answer_codex_terminal_color_query(event)
  if type(event) ~= "table" or not codex_terminal_buffer(event.buf) then
    return
  end
  local sequence = event.data and event.data.sequence
  if type(sequence) ~= "string" then
    return
  end

  local slot
  -- TermRequest strips the final BEL/ST terminator from `sequence`; use plain
  -- prefix checks so a future OSC payload cannot be interpreted as a query.
  if sequence:find("\027]10;?", 1, true) then
    slot = 10
  elseif sequence:find("\027]11;?", 1, true) then
    slot = 11
  else
    return
  end

  local foreground, background = current_editor_colors()
  local response = osc_rgb_response(slot, slot == 10 and foreground or background)
  local channel = vim.bo[event.buf].channel
  if response and type(channel) == "number" and channel > 0 then
    pcall(vim.api.nvim_chan_send, channel, response)
  end
end

vim.api.nvim_create_autocmd("TermRequest", {
  group = vim.api.nvim_create_augroup("PersonalNvimCodexTerminalTheme", { clear = true }),
  callback = answer_codex_terminal_color_query,
})

local function refresh_codecompanion_theme()
  -- CodeCompanion creates its chat and prompt buffers after the colorscheme
  -- has usually been loaded.  Give both surfaces theme-aware links instead
  -- of copying a color once; switching from a dark to a white scheme then
  -- updates already-open chats and `codecompanion_input` floats as well.
  vim.api.nvim_set_hl(0, "CodeCompanionChatNormal", { link = "NormalFloat" })
  vim.api.nvim_set_hl(0, "CodeCompanionChatNormalNC", { link = "NormalFloat" })
  vim.api.nvim_set_hl(0, "CodeCompanionInputNormal", { link = "NormalFloat" })
  vim.api.nvim_set_hl(0, "CodeCompanionInputNormalNC", { link = "NormalFloat" })

  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      local bufnr = vim.api.nvim_win_get_buf(winid)
      local filetype = vim.bo[bufnr].filetype
      local target
      if filetype == "codecompanion" then
        target = "CodeCompanionChatNormal"
      elseif filetype == "codecompanion_input" then
        target = "CodeCompanionInputNormal"
      end
      if target then
        local existing = vim.wo[winid].winhighlight or ""
        local kept = {}
        for mapping in existing:gmatch("[^,]+") do
          local group = mapping:match("^([^:]+):")
          if group and group ~= "Normal" and group ~= "NormalNC" and group ~= "NormalFloat" then
            kept[#kept + 1] = mapping
          end
        end
        kept[#kept + 1] = "Normal:" .. target
        kept[#kept + 1] = "NormalNC:" .. target .. "NC"
        vim.wo[winid].winhighlight = table.concat(kept, ",")
      end
    end
  end
end

-- Keep diff semantics stable across every installed colorscheme.  Theme
-- plugins normally link these groups to their own palette, which made a
-- Codex edit look different (and occasionally indistinguishable) after a
-- theme switch.  The editor uses a green block for text that exists only in
-- the current buffer and a red block for reference/deleted text.  A neutral
-- amber is reserved for a generic changed hunk where neither side is
-- exclusively an insertion or deletion.
local function apply_diff_highlights()
  local add = { bg = "#1f6f3d", fg = "#eaffef", bold = true }
  local delete = { bg = "#8f2934", fg = "#fff0f2", bold = true }
  local change = { bg = "#6b551c", fg = "#fff2be" }

  local function set_group(name, spec)
    -- Explicit definitions (without default/link) intentionally win over a
    -- theme's links.  Re-applying after ColorScheme keeps that guarantee for
    -- both dark and light themes.
    vim.api.nvim_set_hl(0, name, spec)
  end

  -- Native Vim diff groups and common gutter fallbacks.
  for _, name in ipairs({
    "DiffAdd",
    "DiffAddedGutter",
    "diffAdded",
    "Added",
    "GitGutterAdd",
    "GitGutterAddLine",
    "SignifySignAdd",
    "SignifyLineAdd",
  }) do
    set_group(name, add)
  end
  for _, name in ipairs({
    "DiffDelete",
    "DiffRemovedGutter",
    "diffRemoved",
    "Removed",
    "GitGutterDelete",
    "GitGutterDeleteLine",
    "SignifySignDelete",
    "SignifyLineDelete",
  }) do
    set_group(name, delete)
  end
  for _, name in ipairs({
    "DiffChange",
    "DiffText",
    "DiffModifiedGutter",
    "diffChanged",
    "Changed",
    "GitGutterChange",
    "GitGutterChangeLine",
    "SignifySignChange",
    "SignifyLineChange",
  }) do
    set_group(name, change)
  end

  -- mini.diff signs and inline overlay.  OverChange is the old/reference
  -- text (red); OverChangeBuf is the new/current text (green).
  for _, name in ipairs({
    "MiniDiffSignAdd",
    "MiniDiffOverAdd",
    "MiniDiffOverChangeBuf",
  }) do
    set_group(name, add)
  end
  for _, name in ipairs({
    "MiniDiffSignDelete",
    "MiniDiffOverDelete",
    "MiniDiffOverChange",
  }) do
    set_group(name, delete)
  end
  set_group("MiniDiffSignChange", change)

  -- GitSigns has separate number/line/cursor/staged variants.  Defining the
  -- family here prevents a theme from reintroducing a different hue when a
  -- hunk is shown in the sign column, line number, or inline preview.
  for _, prefix in ipairs({ "GitSigns", "GitSignsStaged" }) do
    for _, suffix in ipairs({ "Add", "AddNr", "AddLn", "AddCul", "AddInline", "AddLnInline" }) do
      set_group(prefix .. suffix, add)
    end
    for _, suffix in ipairs({ "Delete", "DeleteNr", "DeleteLn", "DeleteCul", "DeleteInline", "DeleteLnInline" }) do
      set_group(prefix .. suffix, delete)
    end
    for _, suffix in ipairs({ "Change", "ChangeNr", "ChangeLn", "ChangeCul", "ChangeInline", "ChangeLnInline" }) do
      set_group(prefix .. suffix, change)
    end
  end
  for _, name in ipairs({
    "GitSignsDeleteVirtLn",
    "GitSignsDeleteVirtLnInLine",
    "GitSignsDeletePreview",
  }) do
    set_group(name, delete)
  end
  for _, name in ipairs({ "GitSignsAddPreview" }) do
    set_group(name, add)
  end
  for _, name in ipairs({ "GitSignsChangePreview" }) do
    set_group(name, change)
  end
end

_G.ApplyDiffHighlights = apply_diff_highlights
apply_diff_highlights()

-- Playwright and similar tools write browser output to files named
-- console-<timestamp>.log.  Treat those files as a console transcript rather
-- than as source code: line numbers and the sign column only add noise, while
-- level/timestamp highlighting makes a long run scannable at a glance.
local console_log_match_ids = {}
local console_log_states = {}

local function is_console_log_path(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  local basename = vim.fn.fnamemodify(path, ":t")
  return basename:match("^console%-.+%.log$") ~= nil
end

local function console_log_is_noise(line)
  if type(line) ~= "string" then
    return false
  end
  local lower = line:lower()
  -- These are browser/framework heartbeats rather than application output.
  -- Keep all errors and warnings (including HMR/WebSocket failures) visible.
  return lower:find("download the react devtools", 1, true) ~= nil
    or lower:find("[log] [hmr] connected", 1, true) ~= nil
    or lower:find("[log] [fast refresh] rebuilding", 1, true) ~= nil
    or lower:find("[log] [fast refresh] done", 1, true) ~= nil
end

local function filter_console_log_buffer(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not vim.b[bufnr].personal_console_log then
    return
  end

  local state = console_log_states[bufnr]
  if state then
    return
  end

  local original = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local filtered = {}
  for _, line in ipairs(original) do
    if not console_log_is_noise(line) then
      filtered[#filtered + 1] = line
    end
  end

  state = {
    original = vim.deepcopy(original),
    filtered = vim.deepcopy(filtered),
    showing_all = false,
  }
  console_log_states[bufnr] = state
  vim.b[bufnr].personal_console_log_showing_all = false

  if #filtered == #original then
    return
  end
  if #filtered == 0 then
    filtered = { "(Bu projeye ait console kaydı bulunamadı.)" }
    state.filtered = vim.deepcopy(filtered)
  end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, filtered)
  vim.bo[bufnr].modified = false
end

local function restore_console_log_buffer(bufnr, show_all)
  local state = console_log_states[bufnr]
  if not state or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local lines = show_all and state.original or state.filtered
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
  state.showing_all = show_all == true
  vim.b[bufnr].personal_console_log_showing_all = state.showing_all
  return true
end

local function toggle_console_log_filter()
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.b[bufnr].personal_console_log then
    vim.notify("Bu buffer bir console-*.log dosyası değil", vim.log.levels.INFO)
    return
  end
  local state = console_log_states[bufnr]
  if not state then
    filter_console_log_buffer(bufnr)
    state = console_log_states[bufnr]
  end
  if state then
    restore_console_log_buffer(bufnr, not state.showing_all)
    vim.cmd("redraw")
  end
end

local function show_project_console_log()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].personal_console_log then
    restore_console_log_buffer(bufnr, false)
  end
end

vim.api.nvim_create_user_command("ConsoleLogToggle", toggle_console_log_filter, {
  desc = "Console logunda proje/gürültü filtresini aç-kapat",
})
vim.api.nvim_create_user_command("ConsoleLogAll", function()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].personal_console_log then
    filter_console_log_buffer(bufnr)
    restore_console_log_buffer(bufnr, true)
  end
end, { desc = "Console logunun ham tüm satırlarını göster" })
vim.api.nvim_create_user_command("ConsoleLogProject", show_project_console_log, {
  desc = "Console logunda yalnızca proje kayıtlarını göster",
})

local function apply_console_log_highlights()
  vim.api.nvim_set_hl(0, "ConsoleLogTimestamp", { fg = "#8b949e" })
  vim.api.nvim_set_hl(0, "ConsoleLogInfo", { fg = "#7dd3fc", bold = true })
  vim.api.nvim_set_hl(0, "ConsoleLogLog", { fg = "#a8b5c5" })
  vim.api.nvim_set_hl(0, "ConsoleLogWarn", { fg = "#f6c453", bold = true })
  vim.api.nvim_set_hl(0, "ConsoleLogError", { fg = "#ff6b6b", bold = true })
  vim.api.nvim_set_hl(0, "ConsoleLogUrl", { fg = "#74c0fc", underline = true })
end

local function configure_console_log_window(winid)
  if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  if not vim.b[bufnr].personal_console_log then
    return
  end

  -- Keep one physical log record per line; horizontal scrolling is less
  -- confusing than wrapping a JSON error into several fake records.
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].foldcolumn = "0"
  vim.wo[winid].cursorline = false
  vim.wo[winid].wrap = false
  vim.wo[winid].linebreak = false
  vim.wo[winid].scrolloff = 2
  vim.wo[winid].sidescrolloff = 4
  vim.wo[winid].colorcolumn = ""

  local old_matches = console_log_match_ids[winid]
  if old_matches then
    for _, match_id in ipairs(old_matches) do
      pcall(vim.fn.matchdelete, match_id, winid)
    end
  end
  local matches = {}
  local patterns = {
    { "ConsoleLogTimestamp", "\\[\\s*[0-9]\\+ms\\s*\\]", 20 },
    { "ConsoleLogError", "\\[\\s*ERROR\\s*\\]", 110 },
    { "ConsoleLogWarn", "\\[\\s*WARN\\s*\\]", 110 },
    { "ConsoleLogWarn", "\\[\\s*WARNING\\s*\\]", 110 },
    { "ConsoleLogInfo", "\\[\\s*INFO\\s*\\]", 110 },
    { "ConsoleLogLog", "\\[\\s*LOG\\s*\\]", 110 },
    { "ConsoleLogUrl", "\\%(https\\?\\|ws\\)://[^[:space:]]\\+", 30 },
  }
  for _, item in ipairs(patterns) do
    local ok, match_id = pcall(vim.fn.matchadd, item[1], item[2], item[3], -1, { window = winid })
    if ok and type(match_id) == "number" and match_id > 0 then
      matches[#matches + 1] = match_id
    end
  end
  console_log_match_ids[winid] = matches
end

local function configure_console_log_buffer(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if not is_console_log_path(path) then
    return false
  end
  vim.b[bufnr].personal_console_log = true
  vim.bo[bufnr].filetype = "consolelog"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].undofile = false
  filter_console_log_buffer(bufnr)
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      configure_console_log_window(winid)
    end
  end
  return true
end

apply_console_log_highlights()
local console_log_group = vim.api.nvim_create_augroup("PersonalNvimConsoleLogView", { clear = true })
vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter", "BufWinEnter", "WinEnter" }, {
  group = console_log_group,
  callback = function(event)
    if event.event == "BufReadPost" or event.event == "BufNewFile" then
      console_log_states[event.buf] = nil
    end
    configure_console_log_buffer(event.buf)
    configure_console_log_window(vim.api.nvim_get_current_win())
  end,
})
vim.api.nvim_create_autocmd("FileChangedShellPost", {
  group = console_log_group,
  callback = function(event)
    if vim.b[event.buf].personal_console_log then
      console_log_states[event.buf] = nil
      configure_console_log_buffer(event.buf)
    end
  end,
})
vim.api.nvim_create_autocmd("BufWipeout", {
  group = console_log_group,
  callback = function(event)
    console_log_states[event.buf] = nil
  end,
})
vim.api.nvim_create_autocmd("WinClosed", {
  group = console_log_group,
  callback = function(event)
    local winid = tonumber(event.match)
    if winid then
      console_log_match_ids[winid] = nil
    end
  end,
})

-- Embedded terminals are output surfaces too.  Disable source-editor-only
-- decorations so shell/Codex output is not prefixed with misleading line
-- numbers or signs.
vim.api.nvim_create_autocmd({ "TermOpen", "BufWinEnter", "WinEnter" }, {
  group = console_log_group,
  callback = function(event)
    local bufnr = event.buf
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "terminal" then
      return
    end
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
        vim.wo[winid].number = false
        vim.wo[winid].relativenumber = false
        vim.wo[winid].signcolumn = "no"
        vim.wo[winid].foldcolumn = "0"
        vim.wo[winid].cursorline = false
        vim.wo[winid].wrap = false
        vim.wo[winid].scrolloff = 0
      end
    end
  end,
})

local function refresh_codex_terminal_theme()
  -- Explicitly map both normal and non-current terminal cells.  Keeping the
  -- other window-local mappings (statusline/winbar) avoids disturbing the
  -- Codex agent bar installed by the surrounding layout.
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if codex_terminal_buffer(bufnr) then
      local existing = vim.wo[winid].winhighlight or ""
      local kept = {}
      for mapping in existing:gmatch("[^,]+") do
        local group = mapping:match("^([^:]+):")
        if group and group ~= "Normal" and group ~= "NormalNC" and group ~= "NormalFloat" then
          kept[#kept + 1] = mapping
        end
      end
      kept[#kept + 1] = "Normal:CodexTerminalNormal"
      kept[#kept + 1] = "NormalNC:CodexTerminalNormalNC"
      kept[#kept + 1] = "NormalFloat:CodexTerminalNormalFloat"
      vim.wo[winid].winhighlight = table.concat(kept, ",")
    end
  end
  -- Links are theme-aware; no hard-coded color survives a later colorscheme.
  vim.api.nvim_set_hl(0, "CodexTerminalNormal", { link = "Normal" })
  vim.api.nvim_set_hl(0, "CodexTerminalNormalNC", { link = "Normal" })
  vim.api.nvim_set_hl(0, "CodexTerminalNormalFloat", { link = "NormalFloat" })
  apply_diff_highlights()
  apply_console_log_highlights()
  refresh_codecompanion_theme()
  vim.cmd("redraw!")
end

_G.RefreshCodexTerminalTheme = refresh_codex_terminal_theme

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("PersonalNvimCodexTerminalThemeRefresh", { clear = true }),
  callback = function()
    -- Theme callbacks can run after the ColorScheme event as well; apply once
    -- now and once on the next loop turn so the final palette is deterministic.
    apply_diff_highlights()
    apply_console_log_highlights()
    vim.schedule(apply_diff_highlights)
    vim.schedule(apply_console_log_highlights)
    vim.schedule(refresh_codex_terminal_theme)
  end,
})

local function apply_colorscheme(name)
  local ok, err = pcall(vim.cmd.colorscheme, name)
  if not ok then
    vim.notify("Tema yüklenemedi (" .. name .. "): " .. tostring(err), vim.log.levels.WARN)
    return
  end

  -- Codex draws its composer inside a Neovim terminal buffer.  The terminal
  -- window itself is not recreated when a colorscheme changes, so make its
  -- unstyled cells follow the new editor background immediately.  ANSI/true
  -- color cells emitted by Codex are intentionally left alone; those belong
  -- to Codex's own TUI palette and are refreshed on the next process start.
  if type(_G.RefreshCodexTerminalTheme) == "function" then
    vim.schedule(_G.RefreshCodexTerminalTheme)
  end
  vim.schedule(apply_diff_highlights)
end

vim.api.nvim_create_user_command("ThemeCatppuccin", function()
  apply_colorscheme("catppuccin-mocha")
end, { desc = "Catppuccin Mocha temasını kullan" })
vim.api.nvim_create_user_command("ThemeCatppuccinLatte", function()
  apply_colorscheme("catppuccin-latte")
end, { desc = "Catppuccin Latte açık temasını kullan" })
vim.api.nvim_create_user_command("ThemeKanagawa", function()
  apply_colorscheme("kanagawa-wave")
end, { desc = "Kanagawa Wave temasını kullan" })
vim.api.nvim_create_user_command("ThemeKanagawaLotus", function()
  apply_colorscheme("kanagawa-lotus")
end, { desc = "Kanagawa Lotus açık temasını kullan" })
vim.api.nvim_create_user_command("ThemeFlexoki", function()
  apply_colorscheme("flexoki-dark")
end, { desc = "Flexoki Dark temasını kullan" })
vim.api.nvim_create_user_command("ThemeFlexokiLight", function()
  apply_colorscheme("flexoki-light")
end, { desc = "Flexoki Light açık temasını kullan" })

local theme_choices = {
  { label = "Catppuccin Mocha", colorscheme = "catppuccin-mocha" },
  { label = "Catppuccin Latte (white)", colorscheme = "catppuccin-latte" },
  { label = "Kanagawa Wave", colorscheme = "kanagawa-wave" },
  { label = "Kanagawa Lotus (white)", colorscheme = "kanagawa-lotus" },
  { label = "Flexoki Dark", colorscheme = "flexoki-dark" },
  { label = "Flexoki Light (white)", colorscheme = "flexoki-light" },
}
local function open_theme_picker()
  local labels = vim.tbl_map(function(item)
    return item.label
  end, theme_choices)
  vim.ui.select(labels, { prompt = "Neovim teması: " }, function(choice)
    if not choice then
      return
    end
    for _, item in ipairs(theme_choices) do
      if item.label == choice then
        apply_colorscheme(item.colorscheme)
        break
      end
    end
  end)
end
vim.api.nvim_create_user_command("ThemeSelect", open_theme_picker, {
  desc = "Koyu veya beyaz Neovim teması seç",
})

-- Resolve the repository from the current file (or nvim-tree root) instead of
-- assuming that Nvim was launched from the repository root.  Diffview's
-- command supports `-C=<path>`, so the editor's working directory does not
-- need to be changed just to inspect a Codex edit.
local function git_root_for_current_context(context_path)
  local candidates = {}
  if type(context_path) == "string" and context_path ~= "" then
    candidates[#candidates + 1] = vim.fn.fnamemodify(context_path, ":p")
  end
  local buffer_name = vim.api.nvim_buf_get_name(0)
  if buffer_name ~= "" and not buffer_name:match("^term://") and not buffer_name:match("^diffview://") then
    candidates[#candidates + 1] = vim.fn.fnamemodify(buffer_name, ":p")
  end

  -- If the editor is focused on an unnamed/settings buffer, the visible tree
  -- can still tell us which project Codex is working in.
  local ok, tree_core = pcall(require, "nvim-tree.core")
  if ok and type(tree_core.get_cwd) == "function" then
    local tree_root = tree_core.get_cwd()
    if type(tree_root) == "string" and tree_root ~= "" then
      candidates[#candidates + 1] = tree_root
    end
  end
  candidates[#candidates + 1] = vim.fn.getcwd()

  local seen = {}
  for _, candidate in ipairs(candidates) do
    candidate = vim.fn.fnamemodify(candidate, ":p")
    if vim.fn.isdirectory(candidate) == 0 then
      candidate = vim.fn.fnamemodify(candidate, ":h")
    end
    if candidate ~= "" and not seen[candidate] then
      seen[candidate] = true
      local result = vim.fn.systemlist({ "git", "-C", candidate, "rev-parse", "--show-toplevel" })
      if vim.v.shell_error == 0 and type(result) == "table" and result[1] and result[1] ~= "" then
        return vim.fn.fnamemodify(result[1], ":p")
      end
    end
  end
end

-- A Git root is needed for Diffview, but not for opening the edited file in
-- the centre editor.  Keep a project-local fallback for folders that are not
-- repositories; avoid silently watching the user's home directory when Nvim
-- was started without a file or explorer root.
local function project_root_for_current_context(context_path)
  local root = git_root_for_current_context(context_path)
  if root then
    return root
  end

  local candidates = {}
  if type(context_path) == "string" and context_path ~= "" then
    candidates[#candidates + 1] = vim.fn.fnamemodify(context_path, ":p")
  end
  local ok, tree_core = pcall(require, "nvim-tree.core")
  if ok and type(tree_core.get_cwd) == "function" then
    local tree_root = tree_core.get_cwd()
    if type(tree_root) == "string" and tree_root ~= "" then
      candidates[#candidates + 1] = tree_root
    end
  end
  local cwd = vim.fn.getcwd()
  if cwd ~= vim.fn.expand("~") then
    candidates[#candidates + 1] = cwd
  end

  for _, candidate in ipairs(candidates) do
    candidate = vim.fn.fnamemodify(candidate, ":p")
    if vim.fn.isdirectory(candidate) == 0 then
      candidate = vim.fn.fnamemodify(candidate, ":h")
    end
    if candidate ~= "" and vim.fn.isdirectory(candidate) == 1 then
      return candidate
    end
  end
end

-- Read the exact pre-edit text once, synchronously, from the Git index.
-- mini.diff's asynchronous Git watcher is excellent for ordinary editing,
-- but a Codex turn can change a file and trigger checktime/index refreshes in
-- the same event loop tick.  That race made some edits render only partially
-- (or not at all).  Codex previews therefore use this explicit snapshot: the
-- current buffer is always compared with the index version that existed
-- before the edit.  Untracked files use an empty reference and appear as one
-- complete green add hunk.
local function git_reference_lines_for_path(path)
  if type(path) ~= "string" or path == "" then
    return nil, nil
  end

  path = vim.fn.fnamemodify(path, ":p")
  local root = git_root_for_current_context(path)
  if not root then
    return nil, nil
  end
  -- macOS commonly exposes /tmp through the /private/tmp symlink.  Resolve
  -- both sides before computing a relative path; otherwise an otherwise valid
  -- untracked/changed file is mistaken for being outside its Git root.
  local fs_realpath = (vim.uv or vim.loop).fs_realpath
  path = (fs_realpath and fs_realpath(path)) or path
  root = (fs_realpath and fs_realpath(root)) or root

  local relative
  if vim.fs and type(vim.fs.relpath) == "function" then
    relative = vim.fs.relpath(root, path)
  end
  if not relative or relative == "" or relative:match("^%.%.") then
    local prefix = root:gsub("/+$", "") .. "/"
    if path:sub(1, #prefix) == prefix then
      relative = path:sub(#prefix + 1)
    end
  end
  if not relative or relative == "" then
    return nil, root
  end

  -- `:0:` is the staged/index snapshot (the same baseline Codex edits are
  -- expected to preserve).  If the file is not indexed, fall back to HEAD so
  -- a staged/renamed path still gets a complete baseline.
  local reference = vim.fn.systemlist({ "git", "-C", root, "show", ":0:" .. relative })
  if vim.v.shell_error == 0 then
    return reference, root
  end

  reference = vim.fn.systemlist({ "git", "-C", root, "show", "HEAD:" .. relative })
  if vim.v.shell_error == 0 then
    return reference, root
  end

  -- A readable path which exists in the worktree but not in either index or
  -- HEAD is untracked.  An empty array is intentional: mini.diff treats it
  -- as an empty file and marks the whole current file as added.
  if vim.fn.filereadable(path) == 1 then
    return {}, root
  end
  return nil, root
end

-- Diffview is intentionally kept available as an explicit Git-history tool,
-- but it is the wrong surface for Codex edits: it opens a second copy of the
-- file in a side-by-side split.  mini.diff's overlay view keeps the real file
-- as the only centre-editor buffer and renders the old/deleted lines inline
-- (red) while highlighting new/added lines (green).
local function setup_mini_diff(mini_diff)
  if type(mini_diff) ~= "table" or type(mini_diff.setup) ~= "function" then
    return nil
  end
  if type(_G.MiniDiff) == "table" then
    apply_diff_highlights()
    return _G.MiniDiff
  end
  mini_diff.setup({
    view = {
      style = "sign",
      signs = { add = "│", change = "│", delete = "_" },
    },
    options = {
      algorithm = "histogram",
      indent_heuristic = true,
      linematch = 60,
      wrap_goto = false,
    },
  })
  apply_diff_highlights()
  return _G.MiniDiff or mini_diff
end

local function ensure_mini_diff()
  local ok, mini_diff = pcall(require, "mini.diff")
  if ok and type(mini_diff) == "table" then
    return setup_mini_diff(mini_diff)
  end

  -- mini.nvim is normally loaded on VeryLazy.  Codex can emit an edit before
  -- that event on a fast startup, so load the plugin on demand rather than
  -- silently falling back to a split or leaving the edit invisible.
  local lazy_ok, lazy = pcall(require, "lazy")
  if lazy_ok and lazy and type(lazy.load) == "function" then
    pcall(lazy.load, { plugins = { "mini.nvim" } })
  end
  ok, mini_diff = pcall(require, "mini.diff")
  if ok and type(mini_diff) == "table" then
    return setup_mini_diff(mini_diff)
  end
  return nil
end

local function close_existing_diffview()
  local has_diffview = false
  local lib_ok, diffview_lib = pcall(require, "diffview.lib")
  if lib_ok and diffview_lib and type(diffview_lib.get_current_view) == "function" then
    has_diffview = diffview_lib.get_current_view() ~= nil
  end

  if not has_diffview then
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(winid) then
        local bufnr = vim.api.nvim_win_get_buf(winid)
        local name = vim.api.nvim_buf_get_name(bufnr)
        if name:match("^diffview://") then
          has_diffview = true
          break
        end
      end
    end
  end

  if has_diffview and vim.fn.exists(":DiffviewClose") == 2 then
    pcall(vim.cmd, "DiffviewClose")
    return true
  end
  return false
end

local function enable_codex_inline_overlay(bufnr, reference_lines)
  if type(bufnr) ~= "number" or bufnr <= 0 or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local mini_diff = ensure_mini_diff()
  if not mini_diff then
    vim.notify("Inline diff için mini.diff yüklenemedi", vim.log.levels.WARN)
    return false
  end

  -- mini.diff deliberately only attaches to normal, listed text buffers.
  -- Native codex.nvim proposed buffers are converted to that shape by the
  -- pending-diff adapter below before this function is called.
  vim.b[bufnr].personal_codex_diff = true
  vim.bo[bufnr].buflisted = true

  local data = type(mini_diff.get_buf_data) == "function" and mini_diff.get_buf_data(bufnr) or nil
  if reference_lines ~= nil and type(mini_diff.gen_source) == "table"
      and type(mini_diff.gen_source.none) == "function" then
    -- Proposed codex buffers have a synthetic name, so the Git source cannot
    -- resolve them through fs_realpath.  Use the explicit old-file text as a
    -- reference and keep Git's asynchronous source from replacing it.
    if data and type(mini_diff.disable) == "function" then
      pcall(mini_diff.disable, bufnr)
      data = nil
    end
    vim.b[bufnr].minidiff_config = { source = { mini_diff.gen_source.none() } }
  end
  if not data and type(mini_diff.enable) == "function" then
    pcall(mini_diff.enable, bufnr)
  end

  -- A Codex diff always has an explicit reference (the old file contents from
  -- the Git index, or an empty array for an untracked file).  Setting a
  -- reference after enabling makes the preview deterministic even when Git's
  -- asynchronous index watcher and checktime run in the same turn.
  if reference_lines ~= nil and type(mini_diff.set_ref_text) == "function" then
    pcall(mini_diff.set_ref_text, bufnr, reference_lines)
  end

  local function show_overlay()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local current = type(mini_diff.get_buf_data) == "function" and mini_diff.get_buf_data(bufnr) or nil
    if current and not current.overlay and type(mini_diff.toggle_overlay) == "function" then
      pcall(mini_diff.toggle_overlay, bufnr)
    end
    vim.cmd("redraw!")
  end
  -- Git references are populated asynchronously; toggling after the next
  -- event-loop turn keeps the overlay active for both fast and slow repos.
  vim.schedule(show_overlay)
  vim.defer_fn(show_overlay, 80)
  return true
end

-- Convert codex.nvim's temporary two-window proposal into one normal editor
-- buffer.  The plugin's active-diff state and BufWriteCmd/BufDelete handlers
-- remain intact, so accept/reject/close_tab semantics are unchanged.
collapse_pending_codex_diff = function(diff, params)
  if type(params) ~= "table" or type(params.tab_name) ~= "string" then
    return
  end
  local active = diff._get_active_diffs and diff._get_active_diffs() or {}
  local state = active[params.tab_name]
  if type(state) ~= "table" or not state.new_buffer then
    return
  end

  local new_buf = state.new_buffer
  local new_win = state.new_window
  if not vim.api.nvim_buf_is_valid(new_buf) or not new_win or not vim.api.nvim_win_is_valid(new_win) then
    return
  end

  -- Capture the old side before closing its window.  It is still the file on
  -- disk because openDiff has not been accepted yet.
  local old_lines = {}
  if type(params.old_file_path) == "string" and vim.fn.filereadable(params.old_file_path) == 1 then
    local ok, lines = pcall(vim.fn.readfile, params.old_file_path)
    if ok and type(lines) == "table" then
      old_lines = lines
    end
  end

  local old_win = state.target_window
  if old_win and old_win ~= new_win and vim.api.nvim_win_is_valid(old_win) then
    pcall(vim.api.nvim_win_call, old_win, function()
      pcall(vim.cmd, "diffoff")
    end)
    -- Keep the proposed buffer's window as the sole centre editor pane.  The
    -- tree and Codex terminal windows are outside this split and remain put.
    pcall(vim.api.nvim_win_close, old_win, true)
  end
  -- Some codex.nvim releases expose the original window only after a
  -- scheduled layout update.  Resolve that race by closing any remaining
  -- normal window that still displays the exact old file, while preserving
  -- the proposed window.  This is what guarantees one centre file tab even
  -- when the plugin's state metadata arrives late.
  if type(params.old_file_path) == "string" and params.old_file_path ~= "" then
    local expected_path = (vim.uv or vim.loop).fs_realpath(params.old_file_path)
      or vim.fn.fnamemodify(params.old_file_path, ":p")
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
      if winid ~= new_win and vim.api.nvim_win_is_valid(winid) then
        local candidate_buf = vim.api.nvim_win_get_buf(winid)
        local candidate_path = vim.api.nvim_buf_get_name(candidate_buf)
        local candidate_real = candidate_path ~= "" and ((vim.uv or vim.loop).fs_realpath(candidate_path)
          or vim.fn.fnamemodify(candidate_path, ":p")) or ""
        if candidate_real ~= "" and candidate_real == expected_path then
          pcall(vim.api.nvim_win_call, winid, function()
            pcall(vim.cmd, "diffoff")
          end)
          pcall(vim.api.nvim_win_close, winid, true)
        end
      end
    end
  end
  state.target_window = nil

  pcall(vim.api.nvim_set_current_win, new_win)
  pcall(vim.api.nvim_win_call, new_win, function()
    pcall(vim.cmd, "diffoff")
  end)

  -- Keep the temporary buffer writable through codex.nvim's existing
  -- BufWriteCmd handler, while making it eligible for bufferline and
  -- mini.diff.  The handler still intercepts :write and resolves the MCP
  -- operation instead of writing this scratch name to disk.
  vim.bo[new_buf].buftype = ""
  vim.bo[new_buf].buflisted = true
  vim.bo[new_buf].bufhidden = "wipe"
  vim.bo[new_buf].swapfile = false
  vim.b[new_buf].personal_codex_diff = true
  vim.b[new_buf].codex_diff_file_path = params.old_file_path

  enable_codex_inline_overlay(new_buf, old_lines)
  vim.cmd("redraw!")
end

-- Doğrudan Codex terminalinden yapılan değişiklikleri tek komutla yenile ve
-- çalışma ağacı diff'ini aç. codex.nvim'in openDiff akışı yerel değişiklikleri
-- otomatik önizler; bu komut Git çalışma ağacı için tamamlayıcıdır.
open_codex_diff = function(context_path)
  if type(context_path) == "table" then
    context_path = context_path.args
  end
  if type(context_path) ~= "string" or context_path == "" then
    local current_name = vim.api.nvim_buf_get_name(0)
    if current_name ~= "" and not current_name:match("^term://") and not current_name:match("^diffview://") then
      context_path = current_name
    else
      context_path = nil
    end
  end
  local normalized_context
  local reference_lines
  local reference_root
  if type(context_path) == "string" and context_path ~= "" then
    normalized_context = vim.fn.fnamemodify(context_path, ":p")
    reference_lines, reference_root = git_reference_lines_for_path(normalized_context)
    -- Close an older side-by-side view before selecting the centre editor.
    -- Diffview's right pane otherwise looks like a second file tab and can be
    -- mistaken for the requested single-file Codex preview.
    close_existing_diffview()
    -- Make the edited file visible in the centre editor even when Git is not
    -- available; the file itself is still useful in that case.
    if vim.fn.filereadable(normalized_context) == 1 and open_edited_files_in_center then
      local opened = open_edited_files_in_center({ normalized_context })
      local bufnr = opened and opened[1] or vim.fn.bufnr(normalized_context)
      if bufnr and bufnr > 0 then
        enable_codex_inline_overlay(bufnr, reference_lines)
      end
    end
  end
  refresh_current_buffer()
  vim.defer_fn(function()
    local root = reference_root or git_root_for_current_context(normalized_context or context_path)
    if not root then
      if normalized_context then
        vim.notify("Git deposu yok; değişen dosya merkez editörde açıldı (inline diff için Git gerekir).", vim.log.levels.INFO)
      else
        vim.notify(
          "Diff açılamadı: bu dosya/klasörün üstünde Git deposu bulunamadı (F5'i proje içinde kullanın).",
          vim.log.levels.WARN
        )
      end
      return
    end

    if normalized_context then
      local bufnr = vim.fn.bufnr(normalized_context)
      if bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
        enable_codex_inline_overlay(bufnr, reference_lines)
      end
      vim.notify("Codex değişikliği merkez sekmede inline gösteriliyor (yeşil: eklendi, kırmızı: silindi).", vim.log.levels.INFO)
    else
      vim.notify("Codex değişiklikleri merkez sekmelerde inline gösteriliyor.", vim.log.levels.INFO)
    end
  end, 80)
end

local function close_codex_inline_diff()
  local closed_diffview = close_existing_diffview()
  local mini_diff = ensure_mini_diff()
  local bufnr = vim.api.nvim_get_current_buf()
  if mini_diff and type(mini_diff.get_buf_data) == "function" then
    local data = mini_diff.get_buf_data(bufnr)
    if data and data.overlay and type(mini_diff.toggle_overlay) == "function" then
      pcall(mini_diff.toggle_overlay, bufnr)
      vim.cmd("redraw!")
      return
    end
  end
  if not closed_diffview then
    vim.notify("Bu dosyada açık bir inline diff yok", vim.log.levels.INFO)
  end
end

-- Open every file reported by CodeCompanion in a normal centre-editor
-- window before Diffview is shown.  This keeps the files in bufferline (and
-- leaves the first one visible when Diffview is closed) while Diffview still
-- provides the explicit old/new review in the editor.
local function is_center_editor_window(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  local cfg = vim.api.nvim_win_get_config(winid)
  if cfg.relative ~= "" or cfg.external or cfg.hide or not cfg.focusable then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(winid)
  local buftype = vim.bo[buf].buftype
  local filetype = vim.bo[buf].filetype
  return buftype == ""
    and not vim.tbl_contains({
      "NvimTree",
      "DiffviewFiles",
      "DiffviewFilePanel",
      "DiffviewFileHistory",
      "Trouble",
      "lazy",
      "qf",
      "codecompanion",
    }, filetype)
end

ensure_center_editor_window = function()
  local current = vim.api.nvim_get_current_win()
  if is_center_editor_window(current) then
    return current
  end
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_center_editor_window(winid) then
      return winid
    end
  end
  pcall(vim.cmd, "belowright new")
  return vim.api.nvim_get_current_win()
end

open_edited_files_in_center = function(paths)
  if type(paths) ~= "table" then
    paths = { paths }
  end
  local editor_win = ensure_center_editor_window()
  local opened = {}
  for _, path in ipairs(paths) do
    if type(path) == "string" and path ~= "" then
      path = vim.fn.fnamemodify(path, ":p")
      if vim.fn.filereadable(path) == 1 then
        local bufnr = vim.fn.bufadd(path)
        if bufnr > 0 then
          pcall(vim.fn.bufload, bufnr)
          vim.bo[bufnr].buflisted = true
          opened[#opened + 1] = bufnr
        end
      end
    end
  end
  if #opened > 0 and vim.api.nvim_win_is_valid(editor_win) then
    vim.api.nvim_set_current_win(editor_win)
    -- Set each buffer once so bufferline remembers all changed files, then
    -- return to the first file reported by the agent.
    for _, bufnr in ipairs(opened) do
      pcall(vim.api.nvim_win_set_buf, editor_win, bufnr)
    end
    pcall(vim.api.nvim_win_set_buf, editor_win, opened[1])
    vim.cmd("redrawtabline")
  end
  return opened
end

-- A mouse-friendly control centre.  Neovim's leader mappings remain useful,
-- but the important actions also have global function-key shortcuts so they
-- work from any normal editor window (and from terminal mode where possible).
-- F1 opens a small, mouse-clickable menu; the same labels are kept visible in
-- the window bar above every normal window.
local control_menu_buf
local control_menu_win
local control_menu_last_action_at = 0
-- A winbar click may open the menu while the original mouse button is still
-- held.  Some UIs then deliver that same release to the newly focused float;
-- without a guard it looks like a click on row 1 and closes the menu again.
-- Ignore only that short hand-off window; subsequent clicks are handled
-- normally by `run_menu_action`.
local control_menu_ignore_release_until = 0
local control_actions
local open_control_menu
local shortcuts_buf
local shortcuts_win
local open_shortcuts
local toggle_control_menu

local function control_command(command)
  local ok, err = pcall(vim.cmd, command)
  if not ok then
    vim.notify("Komut çalıştırılamadı (" .. command .. "): " .. tostring(err), vim.log.levels.WARN)
  end
end

local function cycle_buffer(direction)
  local command
  if direction == "next" then
    command = vim.fn.exists(":BufferLineCycleNext") == 2 and "BufferLineCycleNext" or "bnext"
  else
    command = vim.fn.exists(":BufferLineCyclePrev") == 2 and "BufferLineCyclePrev" or "bprevious"
  end
  control_command(command)
end

-- Bufferline's stock left-click action is `:buffer %d`, which runs in the
-- currently focused window.  That is surprising in the desktop layout: if
-- the user clicks a file tab while focus is in NvimTree or the Codex terminal,
-- the command replaces that panel's buffer and makes the panel appear to
-- disappear.  Always route a tab click to a real centre-editor window and
-- leave tree/terminal panes intact.
local function open_bufferline_buffer(bufnr)
  bufnr = tonumber(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local function apply()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local target_win
    -- If the buffer is already visible in an editor split, focus that split
    -- instead of moving it elsewhere.
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if is_center_editor_window(winid)
          and vim.api.nvim_win_get_buf(winid) == bufnr then
        target_win = winid
        break
      end
    end

    -- Keep the current editor split when the click came from the editor;
    -- otherwise find the first normal editor beside NvimTree/Codex.
    if not target_win then
      local current = vim.api.nvim_get_current_win()
      if is_center_editor_window(current) then
        target_win = current
      else
        for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if is_center_editor_window(winid) then
            target_win = winid
            break
          end
        end
      end
    end

    -- A minimal session may contain only the tree and a terminal.  Reuse the
    -- existing helper to create one safe editor split in that case.
    target_win = target_win or ensure_center_editor_window()
    if not target_win or not vim.api.nvim_win_is_valid(target_win) then
      return
    end

    pcall(vim.api.nvim_set_current_win, target_win)
    pcall(vim.api.nvim_win_set_buf, target_win, bufnr)
    pcall(vim.cmd, "redrawtabline")
  end

  -- Statusline/tabline callbacks run while Neovim is processing the mouse
  -- event.  Deferring the window/buffer mutation avoids textlock errors and
  -- prevents the click-release event from replacing a panel underneath us.
  vim.schedule(apply)
end

local function close_current_buffer()
  local ok, bufremove = pcall(require, "mini.bufremove")
  if ok and type(bufremove.delete) == "function" then
    bufremove.delete(0, false)
    return
  end
  control_command("confirm bdelete")
end

local function open_nvim_settings()
  local path = vim.fn.stdpath("config") .. "/init.lua"
  -- A terminal buffer should not be replaced by the settings file.  Create a
  -- normal split first so the Codex terminal remains available beside it.
  if vim.bo.buftype ~= "" then
    pcall(vim.cmd, "aboveleft new")
  end
  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if not ok then
    vim.notify("Neovim ayarı açılamadı: " .. tostring(err), vim.log.levels.WARN)
  end
end

-- Generic terminal tabs are independent from codex.nvim's managed Codex
-- terminal. Each session keeps its own process and buffer; only one generic
-- terminal window is shown at a time, so opening a new one does not create a
-- pile of narrow splits. The terminal strip below lets the user switch or
-- close them without touching the editor layout.
local terminal_sessions = {}
local terminal_session_order = {}
local terminal_session_next_id = 1
local terminal_session_bar

local function valid_terminal_session(session)
  return type(session) == "table"
    and session.term
    and type(session.term.buf_valid) == "function"
    and session.term:buf_valid()
end

local function redraw_terminal_bars()
  vim.schedule(function()
    pcall(vim.cmd, "redraw")
  end)
end

local function remove_terminal_session(id)
  terminal_sessions[id] = nil
  for index, value in ipairs(terminal_session_order) do
    if value == id then
      table.remove(terminal_session_order, index)
      break
    end
  end
  redraw_terminal_bars()
end

local function hide_terminal_sessions(except_id)
  for id, session in pairs(terminal_sessions) do
    if id ~= except_id and valid_terminal_session(session) then
      pcall(session.term.hide, session.term)
    end
  end
end

local function focus_terminal_session(id)
  local session = terminal_sessions[id]
  if not valid_terminal_session(session) then
    remove_terminal_session(id)
    return nil
  end
  hide_terminal_sessions(id)
  local ok = pcall(function()
    session.term:show():focus()
    if session.term.win and vim.api.nvim_win_is_valid(session.term.win) then
      vim.api.nvim_set_current_win(session.term.win)
      vim.cmd("startinsert")
    end
  end)
  if not ok then
    return nil
  end
  return session
end

local function close_terminal_session(id)
  local session = terminal_sessions[id]
  if not session then
    return
  end
  if valid_terminal_session(session) then
    pcall(session.term.close, session.term)
  elseif session.buf and vim.api.nvim_buf_is_valid(session.buf) then
    pcall(vim.api.nvim_buf_delete, session.buf, { force = true })
  end
  remove_terminal_session(id)
end

local function terminal_command_parts(command)
  if type(command) == "table" then
    return command
  end
  if type(command) ~= "string" or vim.trim(command) == "" then
    return { vim.o.shell }
  end
  local ok, Snacks = pcall(require, "snacks")
  if ok and Snacks and Snacks.terminal and type(Snacks.terminal.parse) == "function" then
    local parsed = Snacks.terminal.parse(command)
    if type(parsed) == "table" and #parsed > 0 then
      return parsed
    end
  end
  return vim.fn.split(command, "\\s\\+")
end

local function open_terminal_session(command, label)
  local ok, Snacks = pcall(require, "snacks")
  if not ok or not Snacks or not Snacks.terminal then
    vim.notify("Snacks terminal yuklenemedi", vim.log.levels.WARN)
    return nil
  end

  local parts = terminal_command_parts(command)
  local id = terminal_session_next_id
  terminal_session_next_id = terminal_session_next_id + 1
  hide_terminal_sessions()

  local term = Snacks.terminal.open(parts, {
    count = 8000 + id,
    cwd = vim.fn.getcwd(),
    interactive = true,
    win = {
      position = "bottom",
      height = 0.30,
      relative = "editor",
      stack = false,
      border = "rounded",
      title = " " .. (label or parts[1] or "Terminal") .. " ",
      title_pos = "center",
    },
  })
  if not term or not term:buf_valid() then
    vim.notify("Terminal baslatilamadi", vim.log.levels.WARN)
    return nil
  end

  local session = {
    id = id,
    term = term,
    buf = term.buf,
    label = label or parts[1] or "Terminal",
    command = parts,
  }
  terminal_sessions[id] = session
  terminal_session_order[#terminal_session_order + 1] = id
  vim.b[term.buf].personal_terminal_id = id
  vim.b[term.buf].personal_terminal_name = session.label
  vim.bo[term.buf].buflisted = false
  pcall(term.on, term, "TermClose", function()
    remove_terminal_session(id)
  end, { buf = true })
  pcall(term.on, term, "BufWipeout", function()
    remove_terminal_session(id)
  end, { buf = true })
  if term.win and vim.api.nvim_win_is_valid(term.win) then
    vim.wo[term.win].winbar = "%{%v:lua.NvimControlBar()%}"
    vim.api.nvim_set_current_win(term.win)
  end
  vim.cmd("startinsert")
  redraw_terminal_bars()
  return session
end

local function new_terminal_session()
  local codex = vim.fn.exepath("codex")
  local opencode = vim.fn.exepath("opencode")
  local claude = vim.fn.exepath("claude")
  if claude == "" then
    claude = vim.fn.exepath("claude-code")
  end
  local choices = {
    { name = "Shell", command = { vim.o.shell }, label = "Shell" },
    { name = "Codex", command = { codex ~= "" and codex or "codex" }, label = "Codex" },
    { name = "OpenCode", command = { opencode ~= "" and opencode or "opencode" }, label = "OpenCode" },
    { name = "Claude Code", command = { claude ~= "" and claude or "claude" }, label = "Claude" },
    { name = "Custom command...", custom = true },
  }
  vim.ui.select(choices, {
    prompt = "Yeni terminal",
    format_item = function(item)
      return item.name
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice.custom then
      vim.ui.input({ prompt = "Terminal komutu: ", default = vim.o.shell }, function(input)
        if input and vim.trim(input) ~= "" then
          open_terminal_session(input, vim.fn.split(vim.trim(input), "\\s\\+")[1] or "Terminal")
        end
      end)
      return
    end
    open_terminal_session(choice.command, choice.label)
  end)
end

terminal_session_bar = function()
  local winid = tonumber(vim.g.statusline_winid) or vim.api.nvim_get_current_win()
  local current_id
  if vim.api.nvim_win_is_valid(winid) then
    current_id = tonumber(vim.b[vim.api.nvim_win_get_buf(winid)].personal_terminal_id)
  end
  local parts = { "%#TabLine#  " }
  for _, id in ipairs(terminal_session_order) do
    local session = terminal_sessions[id]
    if valid_terminal_session(session) then
      local label = current_id == id and ("[" .. session.label .. "*]") or ("[" .. session.label .. "]")
      parts[#parts + 1] = string.format("%%%d@v:lua.TerminalSessionClick@ %s %%T", 8100 + id, label)
    end
  end
  parts[#parts + 1] = "  %8990@v:lua.TerminalSessionClick@ [+ Term] %T"
  parts[#parts + 1] = " %8991@v:lua.TerminalSessionClick@ [X] %T"
  return table.concat(parts) .. "%=%#TabLineSel#  "
end

_G.TerminalSessionClick = function(minwid, _, button)
  local id = tonumber(minwid) or 0
  vim.schedule(function()
    if id == 8990 then
      new_terminal_session()
    elseif id == 8991 then
      local winid = vim.api.nvim_get_current_win()
      local buf = vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) or 0
      close_terminal_session(tonumber(vim.b[buf].personal_terminal_id))
    elseif id >= 8100 then
      focus_terminal_session(id - 8100)
    end
  end)
end

local function terminal_new_command(opts)
  local args = vim.trim(opts.args or "")
  if args == "" then
    new_terminal_session()
    return
  end
  local parts = terminal_command_parts(args)
  open_terminal_session(parts, parts[1] or "Terminal")
end

vim.api.nvim_create_user_command("TerminalNew", terminal_new_command, {
  nargs = "*",
  desc = "Yeni bagimsiz terminal sekmesi ac (komut opsiyonel)",
})
vim.api.nvim_create_user_command("TerminalTab", terminal_new_command, {
  nargs = "*",
  desc = "Yeni bagimsiz terminal sekmesi ac (alias)",
})

-- codex.nvim intentionally owns one terminal.  Extra agents use the same
-- Snacks terminal backend with a distinct `count`, which gives each process
-- its own terminal id while leaving the primary Codex integration untouched.
-- The winbar becomes a small tab strip: [Codex] [A1] [A2] [+] [X].
local codex_agents = {}
local codex_agent_order = {}
local codex_agent_next_id = 1
local codex_agent_bar

local function valid_codex_agent(agent)
  return type(agent) == "table"
    and agent.term
    and type(agent.term.buf_valid) == "function"
    and agent.term:buf_valid()
end

local function codex_main_terminal_win()
  local ok, terminal = pcall(require, "codex.terminal")
  if not ok or type(terminal.get_active_terminal_bufnr) ~= "function" then
    return nil
  end
  local bufnr = terminal.get_active_terminal_bufnr()
  if not bufnr then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
end

local function focus_codex_main()
  local win = codex_main_terminal_win()
  if win then
    vim.api.nvim_set_current_win(win)
    vim.cmd("startinsert")
  elseif vim.fn.exists(":Codex") == 2 then
    pcall(vim.cmd, "Codex")
  end
end

local function focus_codex_input()
  local win = vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) or not codex_terminal_buffer(vim.api.nvim_win_get_buf(win)) then
    win = codex_main_terminal_win()
  end
  if win and vim.api.nvim_win_is_valid(win) then
    local bufnr = vim.api.nvim_win_get_buf(win)
    attach_codex_terminal_scroll(bufnr)
    schedule_codex_terminal_bottom(bufnr, 0)
    vim.api.nvim_set_current_win(win)
    vim.cmd("startinsert")
  else
    focus_codex_main()
  end
end

local function remove_codex_agent(id)
  codex_agents[id] = nil
  for index, value in ipairs(codex_agent_order) do
    if value == id then
      table.remove(codex_agent_order, index)
      break
    end
  end
end

local function close_codex_agent(id)
  if not id or id == 0 then
    local ok, terminal = pcall(require, "codex.terminal")
    if ok and terminal and type(terminal.close) == "function" then
      pcall(terminal.close)
    end
    return
  end
  local agent = codex_agents[id]
  if not agent then
    return
  end
  if valid_codex_agent(agent) then
    pcall(agent.term.close, agent.term)
  elseif agent.buf and vim.api.nvim_buf_is_valid(agent.buf) then
    pcall(vim.api.nvim_buf_delete, agent.buf, { force = true })
  end
  remove_codex_agent(id)
  vim.schedule(function()
    vim.cmd("redraw")
  end)
end

local function open_codex_agent(id)
  id = tonumber(id)
  if not id or id < 1 then
    id = codex_agent_next_id
    codex_agent_next_id = codex_agent_next_id + 1
  end
  local known_id = false
  for _, known in ipairs(codex_agent_order) do
    if known == id then
      known_id = true
      break
    end
  end
  if not known_id then
    codex_agent_order[#codex_agent_order + 1] = id
  end
  if id >= codex_agent_next_id then
    codex_agent_next_id = id + 1
  end

  local existing = codex_agents[id]
  if valid_codex_agent(existing) then
    if existing.term.win_valid and existing.term:win_valid() then
      existing.term:show():focus()
    else
      existing.term:show():focus()
    end
    vim.cmd("startinsert")
    return existing
  end

  local ok, Snacks = pcall(require, "snacks")
  if not ok or not Snacks or not Snacks.terminal then
    vim.notify("Ek Codex agenti için Snacks terminali yüklenemedi", vim.log.levels.WARN)
    return nil
  end

  local codex = vim.fn.exepath("codex")
  if codex == "" then
    codex = "codex"
  end
  local cwd = vim.fn.getcwd()
  local term = Snacks.terminal.open({ codex }, {
    count = 7000 + id,
    cwd = cwd,
    env = {
      ENABLE_IDE_INTEGRATION = "true",
      FORCE_CODE_TERMINAL = "true",
    },
    interactive = true,
    win = {
      position = "right",
      width = 0.34,
      relative = "editor",
      border = "rounded",
      title = " Codex Agent " .. tostring(id) .. " ",
      title_pos = "center",
    },
  })
  if not term or not term:buf_valid() then
    vim.notify("Codex agenti başlatılamadı", vim.log.levels.WARN)
    return nil
  end

  codex_agents[id] = { id = id, term = term, buf = term.buf, cwd = cwd }
  vim.b[term.buf].codex_agent_id = id
  vim.b[term.buf].codex_agent_name = "Agent " .. tostring(id)
  vim.bo[term.buf].buflisted = false
  pcall(term.on, term, "TermClose", function()
    remove_codex_agent(id)
    vim.schedule(function()
      vim.cmd("redraw")
    end)
  end, { buf = true })
  pcall(term.on, term, "BufWipeout", function()
    remove_codex_agent(id)
  end, { buf = true })
  if term.win and vim.api.nvim_win_is_valid(term.win) then
    vim.wo[term.win].winbar = "%{%v:lua.NvimControlBar()%}"
    vim.api.nvim_set_current_win(term.win)
  end
  vim.cmd("startinsert")
  vim.cmd("redraw")
  return codex_agents[id]
end

local function new_codex_agent()
  return open_codex_agent()
end

-- CodeCompanion's ACP adapter can also host independent Codex sessions.  This
-- companion command uses the plugin's native tab layout, so an agent that
-- edits files still flows through CodeCompanionFileEdited and the centre
-- editor hook above.  It complements the terminal agent tabs rather than
-- reusing the singleton chat opened by <leader>ac.
local function new_codex_chat_agent()
  local ok, codecompanion = pcall(require, "codecompanion")
  if not ok then
    local lazy_ok, lazy = pcall(require, "lazy")
    if lazy_ok and lazy and type(lazy.load) == "function" then
      pcall(lazy.load, { plugins = { "codecompanion.nvim" } })
      ok, codecompanion = pcall(require, "codecompanion")
    end
  end
  if not ok or not codecompanion or type(codecompanion.chat) ~= "function" then
    vim.notify("CodeCompanion Codex agenti yüklenemedi", vim.log.levels.WARN)
    return nil
  end
  local chat = codecompanion.chat({
    params = { adapter = "codex" },
    window_opts = { layout = "tab" },
    yolo_mode = codex_yolo_enabled(),
  })
  if chat and chat.bufnr then
    vim.b[chat.bufnr].codex_chat_agent = true
  end
  return chat
end

local function codex_agent_current_id(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return nil
  end
  local buf = vim.api.nvim_win_get_buf(winid)
  return tonumber(vim.b[buf].codex_agent_id)
end

codex_agent_bar = function()
  local winid = tonumber(vim.g.statusline_winid) or vim.api.nvim_get_current_win()
  local active_id = codex_agent_current_id(winid)
  local parts = { "%#TabLine#  " }
  local main_active = active_id == nil and codex_main_terminal_win() == winid
  parts[#parts + 1] = string.format("%%7000@v:lua.CodexAgentClick@ %s %%T", main_active and "[Codex*]" or "[Codex]")
  table.sort(codex_agent_order)
  for _, id in ipairs(codex_agent_order) do
    local agent = codex_agents[id]
    if valid_codex_agent(agent) then
      local label = active_id == id and ("[A" .. id .. "*]") or ("[A" .. id .. "]")
      parts[#parts + 1] = string.format("%%%d@v:lua.CodexAgentClick@ %s %%T", 7000 + id, label)
    end
  end
  parts[#parts + 1] = "  "
  parts[#parts + 1] = "%7990@v:lua.CodexAgentClick@ [+ Agent] %T"
  parts[#parts + 1] = "%7995@v:lua.CodexAgentClick@ [+ Term] %T"
  parts[#parts + 1] = "%7994@v:lua.CodexAgentClick@ [INPUT] %T"
  -- Keep the same theme/menu controls available while focus is inside the
  -- Codex terminal; the normal editor winbar is not visible in this pane.
  parts[#parts + 1] = "%7992@v:lua.CodexAgentClick@ [TH] %T"
  parts[#parts + 1] = "%7993@v:lua.CodexAgentClick@ [F1] %T"
  parts[#parts + 1] = "%7991@v:lua.CodexAgentClick@ [X] %T"
  return table.concat(parts) .. "%=%#TabLineSel#  "
end

_G.CodexAgentClick = function(minwid, _, button)
  local id = tonumber(minwid) or 0
  vim.schedule(function()
    if button == "r" then
      close_codex_agent(codex_agent_current_id(vim.api.nvim_get_current_win()) or 0)
    elseif id == 7990 then
      new_codex_agent()
    elseif id == 7995 then
      new_terminal_session()
    elseif id == 7994 then
      focus_codex_input()
    elseif id == 7992 then
      open_theme_picker()
    elseif id == 7993 then
      toggle_control_menu()
    elseif id == 7991 then
      close_codex_agent(codex_agent_current_id(vim.api.nvim_get_current_win()) or 0)
    elseif id == 7000 then
      focus_codex_main()
    elseif id > 7000 then
      open_codex_agent(id - 7000)
    end
  end)
end

_G.CodexAgentBar = codex_agent_bar
vim.api.nvim_create_user_command("CodexAgentNew", new_codex_agent, {
  desc = "Yeni Codex agent sekmesi aç",
})
vim.api.nvim_create_user_command("CodexAgentChatNew", new_codex_chat_agent, {
  desc = "Yeni CodeCompanion Codex agent sekmesi aç",
})
vim.api.nvim_create_user_command("CodexAgent", function(opts)
  local id = tonumber(opts.args)
  open_codex_agent(id)
end, { nargs = "?", desc = "Codex agent sekmesine geç veya oluştur" })
vim.api.nvim_create_user_command("CodexAgentClose", function()
  close_codex_agent(codex_agent_current_id(vim.api.nvim_get_current_win()) or 0)
end, { desc = "Geçerli Codex agent sekmesini kapat" })

control_actions = {
  { key = "F2", label = "Dosya ağacını aç/kapat", run = function() control_command("NvimTreeToggle") end },
  { key = "F3", label = "Yeni Codex agent terminali aç", run = new_codex_agent },
  { key = "F4", label = "Codex terminalini aç/kapat", run = function() control_command("Codex") end },
  { key = "F5", label = "Codex/Git diff görünümünü aç", run = open_codex_diff },
  { key = "F6", label = "Önceki dosya sekmesi", run = function() cycle_buffer("previous") end },
  { key = "F7", label = "Sonraki dosya sekmesi", run = function() cycle_buffer("next") end },
  { key = "F8", label = "Geçerli dosya sekmesini kapat", run = close_current_buffer },
  { key = "F9", label = "CodeCompanion sohbetini aç/kapat", run = function() control_command("CodeCompanionChat Toggle") end },
  { key = "F10", label = "Tanıları Trouble'da aç/kapat", run = function() control_command("Trouble diagnostics toggle") end },
  { key = "Ctrl-S", label = "Dosyayı kaydet (update)", run = function() control_command("update") end },
  { key = "F11", label = "Neovim ayar dosyasını aç", run = open_nvim_settings },
  { key = "F12", label = "Eklenti yöneticisini aç", run = function() control_command("Lazy") end },
  { key = "AG+", label = "Yeni Codex agent sekmesi aç", run = new_codex_agent },
  { key = "AC+", label = "Yeni Codex sohbet agent sekmesi aç", run = new_codex_chat_agent },
  { key = "WEB", label = "Browser/search menüsünü aç", run = function() control_command("Browse") end },
  { key = "TH", label = "Koyu/beyaz tema seç", run = open_theme_picker },
  { key = "T+", label = "Yeni bagimsiz terminal sekmesi ac", run = new_terminal_session },
}

local function close_control_menu()
  if control_menu_win and vim.api.nvim_win_is_valid(control_menu_win) then
    vim.api.nvim_win_close(control_menu_win, true)
  end
  control_menu_win = nil
  control_menu_buf = nil
end

-- A second, read-only help surface keeps the complete keymap discoverable.
-- The compact F1 menu is for actions; pressing `?` there (or running
-- :NvimShortcuts) opens this longer list without requiring a leader key.
local shortcut_groups = {
  {
    title = "GLOBAL (leader gerekmez)",
    entries = {
      { "F1", "Kontrol merkezini aç/kapat" },
      { "F2", "NvimTree dosya ağacını aç/kapat" },
      { "F3", "Yeni Codex agent terminali aç (tekrar ederek A2, A3...)" },
      { "F4", "Codex terminalini aç/kapat" },
      { "F5", "Codex/Git Diffview'i aç" },
      { "F6 / F7", "Önceki / sonraki buffer" },
      { "F8", "Geçerli buffer'ı güvenli kapat" },
      { "F9", "CodeCompanion sohbetini aç/kapat" },
      { "F10", "Trouble tanılarını aç/kapat" },
      { "F11", "Neovim init.lua dosyasını aç" },
      { "F12", "Lazy eklenti yöneticisini aç" },
      { "Ctrl-S", "Dosyayı kaydet (update)" },
      { "Ctrl-Tab", "Sonraki buffer" },
      { "Ctrl-Shift-Tab", "Önceki buffer" },
      { "Header [T+] / <leader>tt", "Yeni bagimsiz terminal sekmesi" },
    },
  },
  {
    title = "CODEx / AI",
    entries = {
      { "<leader>cc", "Codex terminali" },
      { "<leader>cf", "Codex terminaline odaklan" },
      { "<leader>cm", "Codex terminalini büyüt/küçült" },
      { "<leader>cs", "Görsel seçimi Codex'e gönder" },
      { "<leader>ca / <leader>cx", "Diff kabul / reddet" },
      { "<leader>ac", "CodeCompanion sohbeti" },
      { "<leader>ae", "Seçili kodu CodeCompanion ile düzenle" },
      { "<leader>ar", "CodeCompanion code review" },
      { "<leader>am", "CodeCompanion değişiklikleri" },
      { "<leader>ai", "CodeCompanion action palette" },
      { "<leader>cy", "Codex diff YOLO onayını aç/kapat" },
      { ":CodexAgentNew / üstte [+ Agent]", "Yeni Codex agent sekmesi" },
      { ":CodexAgent N", "Agent N sekmesine geç/aç" },
      { ":CodexAgentChatNew", "Yeni ACP Codex sohbet agent sekmesi" },
      { ":TerminalNew", "Shell, Codex, OpenCode, Claude veya ozel komut terminali" },
    },
  },
  {
    title = "DOSYA / DIFF / TANILAR",
    entries = {
      { "<leader>e / <leader>o", "NvimTree aç/kapat / dosyayı bul" },
      { "<leader>p", "NvimTree'de Glimpse önizleme" },
      { "<leader>gd / <leader>gq", "Diff aç / kapat" },
      { "<leader>gh", "Dosya Git geçmişi" },
      { "<leader>xx / <leader>xq", "Trouble tanıları / quickfix" },
      { "<leader>xs / <leader>xl", "Trouble semboller / loclist" },
      { "[c / ]c", "Önceki / sonraki Git hunk" },
      { "<leader>gp / <leader>gP", "Hunk satır içi / floating önizleme" },
      { "<leader>gs / <leader>gr", "Hunk stage / geri al" },
      { "<leader>bb / <leader>bm", "Browser/search / tarayıcı yer imleri" },
      { "Header [TH] THEME", "Header'dan koyu veya beyaz tema seç" },
      { ":ThemeSelect", "Koyu veya beyaz tema seç" },
    },
  },
  {
    title = "MOUSE",
    entries = {
      { "Sol tık", "Dosyayı merkez editörde aç" },
      { "Çift sol tık", "Dosyayı aç veya medyayı önizle" },
      { "Orta tık", "Dosyayı yeni sekmede aç" },
      { "Ctrl + sol tık", "Dikey split'te aç" },
      { "Shift + sol tık", "Yatay split'te aç" },
      { "Sağ tık", "Dosya bilgilerini göster" },
      { "Bufferline X / orta-sağ tık", "Buffer'ı güvenli kapat" },
    },
  },
}

local function close_shortcuts()
  if shortcuts_win and vim.api.nvim_win_is_valid(shortcuts_win) then
    vim.api.nvim_win_close(shortcuts_win, true)
  end
  shortcuts_win = nil
  shortcuts_buf = nil
end

open_shortcuts = function()
  if shortcuts_win and vim.api.nvim_win_is_valid(shortcuts_win) then
    close_shortcuts()
    return
  end
  close_control_menu()

  local lines = {
    "  KISAYOL REHBERİ                         [X] Kapat",
    "  Global F tuşları her modda çalışır • Esc/q: kapat",
    "",
  }
  for _, group in ipairs(shortcut_groups) do
    lines[#lines + 1] = "  " .. group.title
    lines[#lines + 1] = "  " .. string.rep("─", 72)
    for _, entry in ipairs(group.entries) do
      lines[#lines + 1] = string.format("  %-20s  %s", entry[1], entry[2])
    end
    lines[#lines + 1] = ""
  end

  shortcuts_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[shortcuts_buf].buftype = "nofile"
  vim.bo[shortcuts_buf].bufhidden = "wipe"
  vim.bo[shortcuts_buf].swapfile = false
  vim.bo[shortcuts_buf].modifiable = true
  vim.api.nvim_buf_set_lines(shortcuts_buf, 0, -1, false, lines)
  vim.bo[shortcuts_buf].modifiable = false
  vim.bo[shortcuts_buf].filetype = "nvim-shortcuts"

  local width = math.min(96, math.max(58, vim.o.columns - 4))
  local height = math.min(#lines, math.max(12, vim.o.lines - 4))
  shortcuts_win = vim.api.nvim_open_win(shortcuts_buf, true, {
    relative = "editor",
    row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(1, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Neovim Kısayolları ",
    title_pos = "center",
  })
  vim.wo[shortcuts_win].winhl = "Normal:Normal,FloatBorder:FloatBorder,CursorLine:CursorLine"
  vim.wo[shortcuts_win].cursorline = true
  local opts = { buffer = shortcuts_buf, silent = true, nowait = true, noremap = true }
  vim.keymap.set("n", "<Esc>", close_shortcuts, opts)
  vim.keymap.set("n", "q", close_shortcuts, opts)
  vim.keymap.set("n", "x", close_shortcuts, opts)
  vim.keymap.set("n", "<LeftRelease>", function()
    local row = vim.api.nvim_win_get_cursor(shortcuts_win)[1]
    if row == 1 then
      close_shortcuts()
    end
  end, opts)
  vim.keymap.set("n", "<2-LeftMouse>", function()
    local row = vim.api.nvim_win_get_cursor(shortcuts_win)[1]
    if row == 1 then
      close_shortcuts()
    end
  end, opts)
  vim.keymap.set("n", "<RightMouse>", close_shortcuts, opts)
  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = shortcuts_buf,
    once = true,
    callback = function()
      shortcuts_win = nil
      shortcuts_buf = nil
    end,
  })
end

local function run_control_action(index)
  local action = control_actions[index]
  if not action or type(action.run) ~= "function" then
    return
  end
  close_control_menu()
  -- A statusline/winbar click is handled while Nvim is drawing.  Scheduling
  -- the command avoids textlock errors and makes the click reliable.
  vim.schedule(function()
    local ok, err = pcall(action.run)
    if not ok then
      vim.notify("Menü eylemi başarısız: " .. tostring(err), vim.log.levels.WARN)
    end
  end)
end

local function run_menu_action()
  local now = (vim.uv or vim.loop).hrtime() / 1e6
  if now < control_menu_ignore_release_until then
    return
  end
  if now - control_menu_last_action_at < 120 then
    return
  end
  control_menu_last_action_at = now
  vim.defer_fn(function()
    if not control_menu_win or not vim.api.nvim_win_is_valid(control_menu_win) then
      return
    end
    local row = vim.api.nvim_win_get_cursor(control_menu_win)[1]
    if row == 1 then
      close_control_menu()
      return
    end
    -- Three heading lines precede the first action.
    run_control_action(row - 3)
  end, 10)
end

open_control_menu = function()
  if control_menu_win and vim.api.nvim_win_is_valid(control_menu_win) then
    -- Opening the menu is intentionally idempotent.  A few terminal/GUI
    -- frontends report both the mouse press and release to a winbar click
    -- callback; treating the second report as another toggle used to make
    -- the menu flash open and immediately disappear.  `toggle_control_menu`
    -- below is the only path that explicitly closes an already-open menu.
    pcall(vim.api.nvim_set_current_win, control_menu_win)
    return
  end

  local lines = {
    "  KONTROL MERKEZİ                         [X] Kapat",
    "  Satıra tıklayın veya Enter'a basın • ?: tüm kısayollar • Esc/q: kapat",
    "",
  }
  for _, action in ipairs(control_actions) do
    lines[#lines + 1] = string.format("  %-8s  %s", action.key, action.label)
  end

  control_menu_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[control_menu_buf].buftype = "nofile"
  vim.bo[control_menu_buf].bufhidden = "wipe"
  vim.bo[control_menu_buf].swapfile = false
  vim.bo[control_menu_buf].modifiable = true
  vim.api.nvim_buf_set_lines(control_menu_buf, 0, -1, false, lines)
  vim.bo[control_menu_buf].modifiable = false
  vim.bo[control_menu_buf].filetype = "nvim-control-center"

  local width = math.min(78, math.max(48, vim.o.columns - 6))
  local height = math.min(#lines, math.max(8, vim.o.lines - 6))
  control_menu_win = vim.api.nvim_open_win(control_menu_buf, true, {
    relative = "editor",
    row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(1, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Neovim Kontrol Merkezi ",
    title_pos = "center",
  })
  control_menu_ignore_release_until = (vim.uv or vim.loop).hrtime() / 1e6 + 260
  vim.wo[control_menu_win].winhl = "Normal:Normal,FloatBorder:FloatBorder,CursorLine:CursorLine"
  vim.wo[control_menu_win].cursorline = true

  local opts = { buffer = control_menu_buf, silent = true, nowait = true, noremap = true }
  vim.keymap.set("n", "<Esc>", close_control_menu, opts)
  vim.keymap.set("n", "q", close_control_menu, opts)
  vim.keymap.set("n", "x", close_control_menu, opts)
  vim.keymap.set("n", "<CR>", run_menu_action, opts)
  vim.keymap.set("n", "<LeftRelease>", run_menu_action, opts)
  vim.keymap.set("n", "<2-LeftMouse>", run_menu_action, opts)
  vim.keymap.set("n", "<RightMouse>", close_control_menu, opts)
  vim.keymap.set("n", "?", function()
    close_control_menu()
    vim.schedule(open_shortcuts)
  end, opts)
  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = control_menu_buf,
    once = true,
    callback = function()
      control_menu_win = nil
      control_menu_buf = nil
    end,
  })
end

vim.api.nvim_create_user_command("NvimShortcuts", open_shortcuts, {
  desc = "Tüm Neovim kısayollarını göster",
})

-- Function keys should remain usable while the cursor is in an insert or
-- terminal buffer.  Leave that input mode before running a window-changing
-- action; otherwise the action can be inserted as text or delivered to the
-- child process instead of Neovim.
local function leave_input_mode()
  local mode = vim.api.nvim_get_mode().mode
  if mode == "t" then
    local key = vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true)
    vim.api.nvim_feedkeys(key, "n", false)
    return true
  end
  if mode:sub(1, 1) == "i" then
    vim.cmd("stopinsert")
    return true
  end
  return false
end

local function invoke_global_action(action)
  if not action or type(action.run) ~= "function" then
    return
  end
  if leave_input_mode() then
    vim.schedule(function()
      local ok, err = pcall(action.run)
      if not ok then
        vim.notify("Kısayol başarısız (" .. action.key .. "): " .. tostring(err), vim.log.levels.WARN)
      end
    end)
    return
  end
  local ok, err = pcall(action.run)
  if not ok then
    vim.notify("Kısayol başarısız (" .. action.key .. "): " .. tostring(err), vim.log.levels.WARN)
  end
end

toggle_control_menu = function()
  local function toggle()
    if control_menu_win and vim.api.nvim_win_is_valid(control_menu_win) then
      close_control_menu()
    else
      open_control_menu()
    end
  end

  if leave_input_mode() then
    vim.schedule(toggle)
  else
    toggle()
  end
end

vim.api.nvim_create_user_command("NvimMenu", toggle_control_menu, {
  desc = "Neovim kontrol merkezini aç/kapat",
})
vim.api.nvim_create_user_command("NvimControl", toggle_control_menu, {
  desc = "Neovim kontrol merkezini aç/kapat (alias)",
})

-- Function-key mappings are intentionally global.  The leader equivalents
-- below remain as discoverable aliases for users who prefer them.
vim.keymap.set({ "n", "i", "v", "t" }, "<F1>", toggle_control_menu, { silent = true, desc = "Neovim kontrol merkezi" })
for index, action in ipairs(control_actions) do
  local modes = { "n", "i", "v", "t" }
  local lhs = action.key == "Ctrl-S" and "<C-s>" or ("<" .. action.key .. ">")
  vim.keymap.set(modes, lhs, function() invoke_global_action(action) end, { silent = true, desc = action.label })
end
vim.keymap.set({ "n", "t" }, "<C-Tab>", function() cycle_buffer("next") end, { silent = true, desc = "Sonraki dosya sekmesi" })
vim.keymap.set({ "n", "t" }, "<C-S-Tab>", function() cycle_buffer("previous") end, { silent = true, desc = "Önceki dosya sekmesi" })

-- The control header and file tabs intentionally live on different rows:
-- the global tabline is the VibeVim action bar, while the centre editor's
-- winbar renders bufferline immediately underneath it.  This keeps F1/F2/...
-- above the file tabs instead of hiding actions below them.
local function control_header_bar()
  -- tabline spans the whole editor, so use the full screen width here rather
  -- than the width of whichever split happened to be active while rendering.
  local width = vim.o.columns
  local function button(id, label)
    return string.format("%%%d@v:lua.NvimControlClick@ %s %%T", id, label)
  end

  if width < 62 then
    return "%#TabLine#" .. table.concat({
      button(1, "F1 M"),
      button(2, "F2 T"),
      button(3, "F3 A"),
      button(4, "F4 C"),
      button(5, "F5 D"),
      button(8, "F8 ×"),
      button(9, "TH"),
      button(10, "T+"),
    }) .. "%=%#TabLineSel# VibeVim "
  end

  return "%#TabLine# " .. table.concat({
    button(1, "[F1] MENU"),
    button(2, "[F2] TREE"),
    button(3, "[F3] AG+"),
    button(4, "[F4] CODEX"),
    button(5, "[F5] DIFF"),
    button(6, "[F6] <"),
    button(7, "[F7] >"),
    button(8, "[F8] X"),
    button(9, "[TH] THEME"),
    button(10, "[T+] TERMINAL"),
  }) .. "%=%#TabLineSel# VibeVim "
end

local function file_tabs_bar()
  local renderer = rawget(_G, "nvim_bufferline")
  if type(renderer) ~= "function" then
    return "%#TabLine#  DOSYALAR  "
  end
  local ok, rendered = pcall(renderer)
  if ok and type(rendered) == "string" and rendered ~= "" then
    return rendered
  end
  return "%#TabLine#  DOSYALAR  "
end

-- The bar is deliberately plain-text/Unicode rather than icon-dependent, so
-- it remains readable even when a terminal uses a font without Nerd Font
-- glyphs.  Neovim 0.12 evaluates winbar like a statusline; the %@ segments
-- are clickable where the UI supports statusline click handlers.
local function control_winbar()
  local winid = tonumber(vim.g.statusline_winid) or vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) or vim.api.nvim_get_current_buf()
  local ft = vim.bo[buf].filetype
  if vim.b[buf].personal_terminal_id then
    return terminal_session_bar()
  end
  local codex_buffer_ok, codex_buffer = pcall(require, "codex.terminal.buffer")
  if vim.b[buf].codex_agent_id
    or (codex_buffer_ok and codex_buffer and type(codex_buffer.is_codex_terminal_buffer) == "function"
      and codex_buffer.is_codex_terminal_buffer(buf)) then
    return codex_agent_bar()
  end
  if vim.bo[buf].buftype == "prompt" or ft == "TelescopePrompt" or ft == "lazy" then
    return ""
  end
  if ft == "NvimTree" then
    return "%#TabLine#  Dosyalar  "
  end
  if is_center_editor_window(winid) then
    return file_tabs_bar()
  end
  return control_header_bar()
end

local header_actions = {
  [1] = toggle_control_menu,
  [2] = control_actions[1].run,
  [3] = control_actions[2].run,
  -- Keep the remaining visible header buttons tied to their key labels rather
  -- than table positions.
  [4] = control_actions[3].run,
  [5] = control_actions[4].run,
  [6] = control_actions[5].run,
  [7] = control_actions[6].run,
  [8] = control_actions[7].run,
  [9] = open_theme_picker,
  [10] = new_terminal_session,
}
_G.NvimControlClick = function(minwid, clicks, button)
  local id = tonumber(minwid) or 0
  -- Winbar/statusline click handlers are allowed to receive both the mouse
  -- press and release on some terminals.  Most actions are toggles (Codex,
  -- Tree, ...), so running the same callback twice would undo the
  -- first invocation.  Suppress an identical callback arriving in the same
  -- short mouse gesture while still allowing a deliberate later click.
  local click_now = (vim.uv or vim.loop).hrtime() / 1e6
  local click_button = button or "l"
  local click_count = tonumber(clicks) or 1
  local previous = vim.g.personal_nvim_control_click
  if type(previous) == "table"
      and previous.id == id
      and previous.button == click_button
      and previous.clicks == click_count
      and click_now - (tonumber(previous.at) or 0) < 220 then
    return
  end
  vim.g.personal_nvim_control_click = {
    id = id,
    button = click_button,
    clicks = click_count,
    at = click_now,
  }
  if button == "r" then
    toggle_control_menu()
    return
  end
  if clicks and clicks > 1 then
    return
  end
  local action = header_actions[id]
  if action then
    vim.schedule(function()
      -- MENU is an opener when clicked from a winbar.  If press/release is
      -- reported twice, an idempotent opener keeps it visible; keyboard F1
      -- and the explicit :NvimMenu command continue to use the real toggle.
      if id == 1 then
        pcall(open_control_menu)
      else
        pcall(action)
      end
    end)
  end
end
_G.NvimControlBar = control_winbar
_G.NvimTopHeader = control_header_bar
vim.opt.winbar = "%{%v:lua.NvimControlBar()%}"

-- Glimpse intentionally restores focus to the explorer after an inline
-- preview is created.  For a desktop-like single-click flow we put focus on
-- the newly-created/reused media window instead, so video controls (`<CR>`,
-- `h`, `l`) work immediately.  Video buffers use virtual names, hence the
-- marked-window fallback below.
local function focus_glimpse_preview(filepath, preview_kind, source_win, windows_before)
  if preview_kind ~= "image" and preview_kind ~= "video" then
    return
  end

  windows_before = windows_before or {}
  local attempts = 0
  local function focus_preview()
    attempts = attempts + 1
    local renderer_ok, renderer = pcall(require, "glimpse.renderer")
    local preview_buf = renderer_ok and type(renderer.find_by_filepath) == "function"
        and renderer.find_by_filepath(filepath)
      or nil
    local preview_win
    if preview_buf then
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == preview_buf then
          preview_win = win
          break
        end
      end
    end

    if not preview_win and preview_kind == "video" then
      local preview_state_ok, preview_state = pcall(require, "glimpse.preview_state")
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) and win ~= source_win then
          local buf = vim.api.nvim_win_get_buf(win)
          local is_new_image = not windows_before[win] and vim.bo[buf].filetype == "image"
          local is_marked_preview = preview_state_ok
            and type(preview_state.is_marked) == "function"
            and preview_state.is_marked(buf)
          if is_new_image or is_marked_preview then
            preview_win = win
            break
          end
        end
      end
    end

    if preview_win then
      vim.api.nvim_set_current_win(preview_win)
      return
    end
    if attempts < 18 then
      vim.defer_fn(focus_preview, 80)
    end
  end

  vim.defer_fn(focus_preview, 60)
end

local function is_glimpse_candidate(path)
  -- Markdown is source text in this setup, not a media/document preview.
  -- Glimpse reports `.md` files as previewable (using its rendered view),
  -- which made a normal Markdown selection open in a separate floating
  -- renderer instead of the central editor buffer.  Keep all Markdown
  -- variants on the regular `:edit` path so Treesitter and bufferline treat
  -- them exactly like the other source files.
  if type(path) ~= "string" or path == "" then
    return false
  end
  local filetype = vim.filetype.match({ filename = path })
  if filetype == "markdown" or filetype == "markdown_inline" then
    return false
  end
  local lower_path = path:lower()
  if lower_path:match("%.md$")
      or lower_path:match("%.markdown$")
      or lower_path:match("%.mdown$")
      or lower_path:match("%.mkdn$")
      or lower_path:match("%.mkd$")
      or lower_path:match("%.mdwn$")
      or lower_path:match("%.mdtxt$")
      or lower_path:match("%.mdtext$")
      or lower_path:match("%.rmd$")
      or lower_path:match("%.qmd$") then
    return false
  end

  local ok, glimpse = pcall(require, "glimpse")
  if not ok or type(glimpse.is_previewable) ~= "function" then
    return false
  end
  -- `is_previewable` checks Glimpse's actual image/video/archive/model/etc.
  -- registry and does not fall back to synchronous `file`/binary detection.
  local preview_ok, previewable = pcall(glimpse.is_previewable, path)
  return preview_ok and previewable == true
end

-- CodeCompanion's ACP file tools write through the filesystem API, so they do
-- not pass through the codex.nvim diff tab.  The plugin emits a
-- `CodeCompanionFileEdited` User event for every created/edited file.  Queue a
-- single refresh so a multi-file turn opens one centered Diffview instead of
-- one tab per file.  The same path is intentionally used for YOLO and normal
-- mode: YOLO controls the permission prompt, while this hook only controls
-- visibility of the resulting change.
local codecompanion_diff_timer
local codecompanion_edited_paths = {}
local codecompanion_diff_group = vim.api.nvim_create_augroup("CodeCompanionDiffPreview", { clear = true })
vim.api.nvim_create_autocmd("User", {
  group = codecompanion_diff_group,
  pattern = "CodeCompanionFileEdited",
  callback = function(event)
    local data = event.data
    if type(data) ~= "table" then
      return
    end
    local incoming_paths = {}
    if type(data.path) == "string" and data.path ~= "" then
      incoming_paths[#incoming_paths + 1] = data.path
    end
    for _, key in ipairs({ "paths", "files" }) do
      if type(data[key]) == "table" then
        for _, path in ipairs(data[key]) do
          if type(path) == "string" and path ~= "" then
            incoming_paths[#incoming_paths + 1] = path
          end
        end
      end
    end
    if #incoming_paths == 0 then
      return
    end
    for _, path in ipairs(incoming_paths) do
      codecompanion_edited_paths[vim.fn.fnamemodify(path, ":p")] = true
    end
    if codecompanion_diff_timer then
      return
    end

    codecompanion_diff_timer = vim.defer_fn(function()
      codecompanion_diff_timer = nil
      local edited_paths = codecompanion_edited_paths
      codecompanion_edited_paths = {}
      local ordered_paths = vim.tbl_keys(edited_paths)
      table.sort(ordered_paths)

      -- Refresh every loaded buffer touched by the ACP write before asking
      -- Diffview to read the worktree.  `checktime` deliberately keeps local
      -- unsaved edits protected and will warn instead of overwriting them.
      local first_edited_path
      for _, path in ipairs(ordered_paths) do
        first_edited_path = first_edited_path or path
        local bufnr = vim.fn.bufnr(path)
        if bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_call(bufnr, function()
            pcall(vim.cmd, "checktime")
          end)
        end
      end
      open_edited_files_in_center(ordered_paths)
      open_codex_diff(first_edited_path)
    end, 350)
  end,
})

-- Keep CodeCompanion's own approval cache in sync with the Codex CLI mode.
-- ACP edits already inherit `agent-full-access`; this additionally makes
-- CodeCompanion's HTTP inline/tool diffs accept automatically when the same
-- global YOLO setting is active.  Destructive tools that explicitly opt out
-- (`run_command`, `delete_file`) still retain their safety prompt.
vim.api.nvim_create_autocmd("User", {
  group = codecompanion_diff_group,
  pattern = "CodeCompanionChatCreated",
  callback = function(event)
    if not codex_yolo_enabled() or type(event.data) ~= "table" or type(event.data.bufnr) ~= "number" then
      return
    end

    set_codecompanion_yolo(event.data.bufnr, true)
  end,
})

-- The terminal Codex client can apply an edit directly in YOLO mode.  That
-- path does not call CodeCompanion's FileEdited event or codex.nvim's
-- openDiff tool, so watch the active Git worktree as a final integration
-- point.  A changed file is reloaded and opened in the centre editor, then a
-- file-scoped Diffview is shown there.
local codex_edit_watch = {
  handle = nil,
  root = nil,
  timer = nil,
  pending = {},
}
local codex_local_writes = {}

local function codex_now_ms()
  local uv_now = vim.uv and vim.uv.now or vim.loop.now
  return type(uv_now) == "function" and uv_now() or math.floor(vim.loop.hrtime() / 1000000)
end

local function codex_terminal_present()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local terminal_name = tostring(vim.b[bufnr].personal_terminal_name or ""):lower()
      if vim.b[bufnr].codex_agent_id
          or vim.b[bufnr].codex_terminal == true
          or vim.bo[bufnr].filetype == "codecompanion_cli"
          or terminal_name:match("codex")
          or codex_terminal_buffer(bufnr) then
        return true
      end
    end
  end
  return false
end

local function close_codex_edit_watch()
  if codex_edit_watch.timer then
    pcall(function()
      codex_edit_watch.timer:stop()
      codex_edit_watch.timer:close()
    end)
    codex_edit_watch.timer = nil
  end
  if codex_edit_watch.handle then
    pcall(function()
      if not codex_edit_watch.handle:is_closing() then
        codex_edit_watch.handle:stop()
        codex_edit_watch.handle:close()
      end
    end)
    codex_edit_watch.handle = nil
  end
  codex_edit_watch.root = nil
  codex_edit_watch.pending = {}
end

local function ignored_codex_edit_path(root, path)
  if type(path) ~= "string" or path == "" then
    return true
  end
  path = vim.fn.fnamemodify(path, ":p")
  local relative = vim.fs and vim.fs.relpath and vim.fs.relpath(root, path)
  if not relative or relative == "" then
    return true
  end
  if relative:match("^%.git/") or relative == ".git" then
    return true
  end
  if relative:match("^node_modules/") or relative:match("/node_modules/")
      or relative:match("^%.next/") or relative:match("/%.next/")
      or relative:match("^dist/") or relative:match("/dist/")
      or relative:match("^build/") or relative:match("/build/")
      or relative:match("^target/") or relative:match("/target/")
      or relative:match("^coverage/") or relative:match("/coverage/")
      or relative:match("^vendor/") or relative:match("/vendor/") then
    return true
  end
  if relative:match("/%.sw[po]$") or relative:match("~$") or relative:match("%.tmp$") then
    return true
  end
  return vim.fn.filereadable(path) ~= 1
end

local function flush_codex_edit_watch()
  codex_edit_watch.timer = nil
  if not codex_terminal_present() then
    codex_edit_watch.pending = {}
    return
  end

  local pending = codex_edit_watch.pending
  codex_edit_watch.pending = {}
  local paths = vim.tbl_keys(pending)
  table.sort(paths)
  local first_path

  for _, path in ipairs(paths) do
    if vim.fn.filereadable(path) == 1 then
      local bufnr = vim.fn.bufnr(path)
      local modified = bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified
      if not modified then
        if bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_call(bufnr, function()
            pcall(vim.cmd, "checktime")
          end)
        end
        first_path = first_path or path
      else
        vim.notify("Codex değişikliği gösterilemedi: dosyada kaydedilmemiş yerel değişiklik var", vim.log.levels.WARN)
      end
    end
  end

  if not first_path then
    return
  end

  -- Always return to the single centre-editor surface.  If a previous
  -- explicit Diffview is open, open_codex_diff closes it before selecting the
  -- changed file and enabling the inline overlay.
  open_edited_files_in_center({ first_path })
  if package.loaded["gitsigns"] then
    pcall(function()
      require("gitsigns").refresh()
    end)
  end
  open_codex_diff(first_path)
end

local function queue_codex_edit_path(path)
  local root = codex_edit_watch.root
  if not root then
    return
  end
  path = vim.fn.fnamemodify(path, ":p")
  if ignored_codex_edit_path(root, path) then
    return
  end
  local last_local_write = codex_local_writes[path]
  if last_local_write and codex_now_ms() - last_local_write < 1200 then
    return
  end
  codex_edit_watch.pending[path] = true
  if codex_edit_watch.timer then
    return
  end
  codex_edit_watch.timer = vim.defer_fn(flush_codex_edit_watch, 300)
end

local function start_codex_edit_watch()
  local root = project_root_for_current_context()
  if not root then
    close_codex_edit_watch()
    return
  end
  if codex_edit_watch.handle and codex_edit_watch.root == root then
    return
  end
  close_codex_edit_watch()

  local handle = vim.uv.new_fs_event()
  if not handle then
    return
  end
  local ok, started, err = pcall(function()
    return handle:start(root, { recursive = true }, function(event_err, filename)
      if event_err or type(filename) ~= "string" or filename == "" then
        return
      end
      vim.schedule(function()
        if codex_edit_watch.handle == handle then
          local path = filename
          if not path:match("^/") then
            path = root .. "/" .. path
          end
          queue_codex_edit_path(path)
        end
      end)
    end)
  end)
  if not ok or not started then
    pcall(function()
      handle:close()
    end)
    return
  end
  codex_edit_watch.handle = handle
  codex_edit_watch.root = root
end

local codex_edit_watch_group = vim.api.nvim_create_augroup("CodexExternalEditPreview", { clear = true })
vim.api.nvim_create_autocmd("BufWritePost", {
  group = codex_edit_watch_group,
  callback = function(event)
    local path = vim.api.nvim_buf_get_name(event.buf)
    if path ~= "" then
      codex_local_writes[vim.fn.fnamemodify(path, ":p")] = codex_now_ms()
    end
  end,
})
vim.api.nvim_create_autocmd({ "VimEnter", "BufEnter", "TermOpen", "DirChanged" }, {
  group = codex_edit_watch_group,
  callback = function()
    vim.defer_fn(start_codex_edit_watch, 120)
  end,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = codex_edit_watch_group,
  callback = close_codex_edit_watch,
})

vim.api.nvim_create_user_command("CodexDiff", function(opts)
  local path = vim.trim(opts.args or "")
  open_codex_diff(path ~= "" and path or nil)
end, {
  nargs = "?",
  complete = "file",
  desc = "Codex değişikliklerini merkez sekmede inline aç",
})

vim.keymap.set("n", "<leader>gd", open_codex_diff, { desc = "Git/Codex çalışma ağacı diff'i" })
vim.keymap.set("n", "<leader>gq", close_codex_inline_diff, { desc = "Inline diff görünümünü kapat" })
vim.keymap.set("n", "<leader>gh", "<cmd>DiffviewFileHistory %<cr>", { desc = "Dosya Git geçmişi" })
vim.keymap.set("n", "<leader>e", "<cmd>NvimTreeToggle<cr>", { desc = "Dosya yöneticisini aç/kapat" })
vim.keymap.set("n", "<leader>o", "<cmd>NvimTreeFindFileToggle<cr>", { desc = "Dosyayı ağaçta bul" })
vim.keymap.set("n", "<leader>cy", "<cmd>CodexYoloDiff toggle<cr>", { desc = "Codex diff YOLO onayını aç/kapat" })
vim.keymap.set("n", "<leader>wa", new_codex_agent, { desc = "Yeni Codex agent sekmesi" })
vim.keymap.set("n", "<leader>an", new_codex_chat_agent, { desc = "Yeni ACP Codex sohbet sekmesi" })
vim.keymap.set({ "n", "t" }, "<leader>tt", new_terminal_session, { desc = "Yeni bagimsiz terminal sekmesi" })

local function close_menu_surface()
  local filetype = vim.bo.filetype
  if filetype == "NvimTree" then
    pcall(vim.cmd, "NvimTreeClose")
  elseif filetype:match("^Diffview") then
    pcall(vim.cmd, "DiffviewClose")
  elseif filetype == "Trouble" then
    pcall(vim.cmd, "Trouble close")
  elseif filetype == "lazy" then
    pcall(vim.cmd, "q")
  elseif filetype == "codecompanion" then
    if vim.fn.exists(":CodeCompanionChat") == 2 then
      pcall(vim.cmd, "CodeCompanionChat Toggle")
    else
      pcall(vim.cmd, "close")
    end
  elseif filetype == "image" or filetype == "glimpse" or filetype == "Glimpse" or filetype:match("^glimpse_") then
    pcall(vim.cmd, "close")
  elseif vim.bo.buftype == "nofile" then
    pcall(vim.cmd, "close")
  end
end

-- Every floating window is a modal surface in the desktop-style layout:
-- LSP dialogs, Snacks pickers, Glimpse previews and plugin help menus all
-- receive the same visible, mouse-clickable [X].
local modal_filetypes = {
  DiffviewFiles = true,
  DiffviewFilePanel = true,
  DiffviewFileHistory = true,
  Trouble = true,
  lazy = true,
  codecompanion = true,
  image = true,
  glimpse = true,
  Glimpse = true,
  ["nvim-control-center"] = true,
  ["nvim-shortcuts"] = true,
}

local function modal_filetype(filetype)
  return modal_filetypes[filetype]
    or (type(filetype) == "string" and filetype:match("^glimpse_") ~= nil)
end

local function modal_label(filetype)
  if filetype == "codecompanion" then
    return "CODECOMPANION"
  elseif type(filetype) == "string" and filetype:match("^Diffview") then
    return "DIFF"
  elseif filetype == "Trouble" then
    return "TROUBLE"
  end
  return "PANEL"
end

local close_modal_window

local function apply_modal_close_affordance(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  local cfg = vim.api.nvim_win_get_config(winid)
  local buf = vim.api.nvim_win_get_buf(winid)
  local filetype = vim.bo[buf].filetype
  -- Codex's own terminal/tab strip already owns a richer [X] control. Do not
  -- replace it with the generic modal bar when Snacks renders an agent as a
  -- floating terminal.
  if vim.b[buf].codex_agent_id then
    return
  end
  local codex_buffer_ok, codex_buffer = pcall(require, "codex.terminal.buffer")
  if codex_buffer_ok and codex_buffer
      and type(codex_buffer.is_codex_terminal_buffer) == "function"
      and codex_buffer.is_codex_terminal_buffer(buf) then
    return
  end
  local is_float = cfg.relative ~= "" and cfg.focusable ~= false
  if not is_float and not modal_filetype(filetype) then
    return
  end

  vim.wo[winid].winbar = string.format(
    "%%#TabLine# %s %%=%%9999@v:lua.NvimModalCloseClick@ [X] %%T",
    modal_label(filetype)
  )
  vim.wo[winid].winhl = "Normal:NormalFloat,FloatBorder:FloatBorder,CursorLine:CursorLine"

  local close = function()
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(winid) then
        close_modal_window(winid)
      end
    end)
  end
  vim.keymap.set("n", "x", close, { buffer = buf, silent = true, nowait = true, noremap = true })
end

close_modal_window = function(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(winid)
  local filetype = vim.bo[buf].filetype
  -- Statusline clicks report the target window, but Neovim keeps the previous
  -- window as current until the callback returns. Focus the clicked modal so
  -- plugin-native close commands (CodeCompanion, Diffview, Trouble) act on the
  -- surface the user actually selected.
  if vim.api.nvim_get_current_win() ~= winid then
    pcall(vim.api.nvim_set_current_win, winid)
  end
  if filetype == "image" or filetype == "glimpse" or filetype == "Glimpse"
      or (type(filetype) == "string" and filetype:match("^glimpse_")) then
    local ok, glimpse = pcall(require, "glimpse")
    if ok and glimpse and type(glimpse.close) == "function" then
      pcall(glimpse.close)
    end
    pcall(vim.api.nvim_win_close, winid, true)
    return
  elseif filetype == "codecompanion" and vim.fn.exists(":CodeCompanionChat") == 2 then
    pcall(vim.cmd, "CodeCompanionChat Toggle")
    return
  elseif filetype == "DiffviewFiles" or filetype == "DiffviewFilePanel"
      or filetype == "DiffviewFileHistory" then
    pcall(vim.cmd, "DiffviewClose")
    return
  elseif filetype == "Trouble" then
    pcall(vim.cmd, "Trouble close")
    return
  elseif filetype == "lazy" then
    pcall(vim.cmd, "q")
    return
  end

  -- Generic floating panels (LSP, Snacks and plugin help/pickers) can be
  -- closed safely at the window level, including nofile buffers.
  pcall(vim.api.nvim_win_close, winid, true)
end

_G.NvimModalCloseClick = function()
  local winid = tonumber(vim.g.statusline_winid) or vim.api.nvim_get_current_win()
  vim.schedule(function()
    close_modal_window(winid)
  end)
end

local modal_affordance_group = vim.api.nvim_create_augroup("PersonalNvimModalClose", { clear = true })
vim.api.nvim_create_autocmd({ "WinNew", "WinEnter", "BufWinEnter", "FileType" }, {
  group = modal_affordance_group,
  callback = function()
    vim.schedule(function()
      for _, winid in ipairs(vim.api.nvim_list_wins()) do
        apply_modal_close_affordance(winid)
      end
    end)
  end,
})

local menu_surface_events = vim.api.nvim_create_augroup("PersonalNvimMenuSurfaces", { clear = true })
vim.api.nvim_create_autocmd("FileType", {
  group = menu_surface_events,
  pattern = {
    "NvimTree",
    "DiffviewFiles",
    "DiffviewFilePanel",
    "DiffviewFileHistory",
    "Trouble",
    "lazy",
    "codecompanion",
    "glimpse",
    "Glimpse",
    "image",
    "glimpse_*",
  },
  callback = function(event)
    vim.keymap.set("n", "x", close_menu_surface, {
      buffer = event.buf,
      silent = true,
      nowait = true,
      noremap = true,
      desc = "Menüyü/paneli kapat",
    })
  end,
})
vim.api.nvim_create_autocmd("BufEnter", {
  group = menu_surface_events,
  pattern = "*",
  callback = function(event)
    local buf = event.buf
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "nofile" then
      vim.keymap.set("n", "x", close_menu_surface, {
        buffer = buf,
        silent = true,
        nowait = true,
        noremap = true,
        desc = "Menüyü/paneli kapat",
      })
    end
  end,
})

-- Start a practical coding layout when Neovim is launched: the tree on the
-- left, the current file in the centre and the Codex terminal on the right.
-- Chat and diff views stay on demand because they need a prompt or a change.
local startup_layout_group = vim.api.nvim_create_augroup("PersonalNvimStartupLayout", { clear = true })
vim.api.nvim_create_autocmd("VimEnter", {
  group = startup_layout_group,
  callback = function()
    vim.defer_fn(function()
      if #vim.api.nvim_list_uis() == 0 or vim.o.diff then
        return
      end

      local editor_win = vim.api.nvim_get_current_win()
      if vim.fn.exists(":NvimTreeOpen") == 2 then
        pcall(vim.cmd, "NvimTreeOpen")
      end

      local attempts = 0
      local function open_codex_terminal()
        attempts = attempts + 1
        -- `:Codex` is a toggle.  During startup that can hide an already
        -- visible terminal, leaving the layout without Codex.  `:CodexOpen` is idempotent and
        -- always makes the managed terminal visible.
        local open_command = vim.fn.exists(":CodexOpen") == 2 and "CodexOpen"
          or (vim.fn.exists(":Codex") == 2 and "Codex" or nil)
        if open_command then
          pcall(vim.cmd, open_command)
          if vim.api.nvim_win_is_valid(editor_win) then
            vim.api.nvim_set_current_win(editor_win)
            -- codex.nvim focuses its terminal in Insert mode while opening.
            -- Restore Normal mode after returning to the centre editor so
            -- nvim-tree's mouse mappings and global function keys are active.
            vim.cmd("stopinsert")
            vim.defer_fn(function()
              if vim.api.nvim_win_is_valid(editor_win) then
                vim.api.nvim_set_current_win(editor_win)
                vim.cmd("stopinsert")
              end
            end, 60)
          end
          return
        end
        if attempts < 40 then
          vim.defer_fn(open_codex_terminal, 100)
        end
      end

      open_codex_terminal()
    end, 100)
  end,
  desc = "Open the personal coding layout",
})

require("lazy").setup({
  {
    "catppuccin/nvim",
    name = "catppuccin",
    priority = 1000,
    lazy = false,
    opts = {
      flavour = "mocha",
      integrations = {
        treesitter = true,
        gitsigns = true,
        nvimtree = true,
        native_lsp = { enabled = true },
      },
    },
    config = function(_, opts)
      require("catppuccin").setup(opts)
    end,
  },

  {
    "rebelot/kanagawa.nvim",
    -- Yedek tema; yalnızca :ThemeKanagawa çağrıldığında yüklensin.  Üç
    -- temanın aynı anda eager yüklenmesi açılışta gereksiz CPU/RAM harcar.
    lazy = true,
    opts = {
      compile = true,
      undercurl = true,
      commentStyle = { italic = true },
      keywordStyle = { italic = true },
      statementStyle = { bold = true },
      dimInactive = false,
      terminalColors = true,
      theme = "wave",
      background = { dark = "wave", light = "lotus" },
    },
  },

  {
    "kepano/flexoki-neovim",
    name = "flexoki",
    -- Flexoki Dark is the stable default.  Other themes remain available
    -- through :ThemeSelect and are loaded on demand when selected.
    lazy = false,
    priority = 900,
    config = function()
      vim.cmd.colorscheme("flexoki-dark")
    end,
  },

  {
    "nvim-treesitter/nvim-treesitter",
    branch = "master",
    lazy = false,
    build = ":TSUpdate",
    config = function()
      require("nvim-treesitter.configs").setup({
        ensure_installed = {
          "bash",
          "css",
          "html",
          "javascript",
          "json",
          "lua",
          "markdown",
          "markdown_inline",
          "python",
          "query",
          "tsx",
          "typescript",
          "yaml",
          "vim",
          "vimdoc",
        },
        sync_install = false,
        auto_install = false,
        highlight = {
          enable = true,
          additional_vim_regex_highlighting = false,
        },
        indent = {
          enable = true,
        },
      })

      -- nvim-treesitter's current master still assumes that every query
      -- capture is a single TSNode.  Neovim 0.12 returns a list when a
      -- capture can occur more than once; Markdown injection predicates then
      -- call `:range()` on the list and enter an error/redraw loop.  Replace
      -- the affected handlers with a small compatibility shim instead of
      -- editing the lazy-managed plugin directory.
      if vim.fn.has("nvim-0.12") == 1 then
        local query = require("vim.treesitter.query")
        local function capture_node(match, id)
          local node = match[id]
          if type(node) == "table" then
            node = node[1]
          end
          return node
        end

        local function valid_args(name, predicate, count, strict_count)
          local actual = #predicate - 1
          if strict_count and actual ~= count then
            vim.api.nvim_err_writeln(string.format("%s must have exactly %d arguments", name, count))
            return false
          end
          if not strict_count and actual < count then
            vim.api.nvim_err_writeln(string.format("%s must have at least %d arguments", name, count))
            return false
          end
          return true
        end

        local query_compat_opts = { force = true, all = false }
        query.add_predicate("nth?", function(match, _, _, predicate)
          if not valid_args("nth?", predicate, 2, true) then
            return
          end
          local node = capture_node(match, predicate[2])
          local index = tonumber(predicate[3])
          local parent = node and node:parent()
          if node and index and parent and parent:named_child_count() > index then
            return parent:named_child(index) == node
          end
          return false
        end, query_compat_opts)

        query.add_predicate("is?", function(match, _, bufnr, predicate)
          if not valid_args("is?", predicate, 2) then
            return
          end
          local node = capture_node(match, predicate[2])
          if not node then
            return true
          end
          local locals = require("nvim-treesitter.locals")
          local _, _, kind = locals.find_definition(node, bufnr)
          return vim.tbl_contains({ unpack(predicate, 3) }, kind)
        end, query_compat_opts)

        query.add_predicate("kind-eq?", function(match, _, _, predicate)
          if not valid_args(predicate[1], predicate, 2) then
            return
          end
          local node = capture_node(match, predicate[2])
          if not node then
            return true
          end
          return vim.tbl_contains({ unpack(predicate, 3) }, node:type())
        end, query_compat_opts)

        query.add_directive("set-lang-from-mimetype!", function(match, _, bufnr, predicate, metadata)
          local node = capture_node(match, predicate[2])
          if not node then
            return
          end
          local value = vim.treesitter.get_node_text(node, bufnr)
          local aliases = {
            importmap = "json",
            module = "javascript",
            ["application/ecmascript"] = "javascript",
            ["text/ecmascript"] = "javascript",
          }
          if aliases[value] then
            metadata["injection.language"] = aliases[value]
          else
            local parts = vim.split(value, "/", {})
            metadata["injection.language"] = parts[#parts]
          end
        end, query_compat_opts)

        query.add_directive("set-lang-from-info-string!", function(match, _, bufnr, predicate, metadata)
          local node = capture_node(match, predicate[2])
          if not node then
            return
          end
          local alias = vim.treesitter.get_node_text(node, bufnr):lower()
          local aliases = { ex = "elixir", pl = "perl", sh = "bash", uxn = "uxntal", ts = "typescript" }
          metadata["injection.language"] = vim.filetype.match({ filename = "a." .. alias }) or aliases[alias] or alias
        end, query_compat_opts)

        query.add_directive("downcase!", function(match, _, bufnr, predicate, metadata)
          local id = predicate[2]
          local node = capture_node(match, id)
          if not node then
            return
          end
          local text = vim.treesitter.get_node_text(node, bufnr, { metadata = metadata[id] }) or ""
          metadata[id] = metadata[id] or {}
          metadata[id].text = string.lower(text)
        end, query_compat_opts)
      end
    end,
  },

  {
    "nvim-tree/nvim-web-devicons",
    -- Bufferline and nvim-tree both use this provider for file-type glyphs.
    -- The plugin defaults to no fallback icon, which made terminals without
    -- a matching Nerd Font look as if icons were missing altogether.
    lazy = false,
    opts = { default = true },
    config = function(_, opts)
      require("nvim-web-devicons").setup(opts)
    end,
  },

  {
    "akinsho/bufferline.nvim",
    version = "*",
    lazy = false,
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = function()
      local function close_buffer(bufnr)
        local ok, bufremove = pcall(require, "mini.bufremove")
        if ok and type(bufremove.delete) == "function" then
          return bufremove.delete(bufnr, false)
        end

        if vim.api.nvim_buf_is_valid(bufnr) then
          local modified = vim.bo[bufnr].modified
          if modified then
            local choice = vim.fn.confirm("Dosyada kaydedilmemiş değişiklik var", "&Kaydet\n&Kapat\n&İptal", 1)
            if choice == 1 then
              vim.api.nvim_buf_call(bufnr, function() vim.cmd("update") end)
            elseif choice ~= 2 then
              return
            end
          end
          vim.api.nvim_buf_delete(bufnr, { force = false })
        end
      end

      return {
        options = {
          mode = "buffers",
          numbers = "ordinal",
          separator_style = "slant",
          show_buffer_icons = true,
          show_buffer_close_icons = true,
          show_close_icon = false,
          buffer_close_icon = "×",
          modified_icon = "●",
          indicator = { style = "underline" },
          diagnostics = "nvim_lsp",
          -- Give file tabs enough room for their name and close glyph.  The
          -- editor panes remain unchanged; only the tab strip gets wider.
          max_name_length = 50,
          max_prefix_length = 20,
          tab_size = 40,
          name_formatter = function(buf)
            local source_path = vim.b[buf.bufnr].codex_diff_file_path
            if type(source_path) == "string" and source_path ~= "" then
              return vim.fn.fnamemodify(source_path, ":t") .. " [Codex]"
            end
            return buf.name
          end,
          always_show_bufferline = true,
          -- The global tabline is VibeVim's control header.  Keeping
          -- bufferline in buffer mode and disabling its auto-toggle lets the
          -- centre editor render the file tabs in its own winbar below that
          -- header without the plugin reclaiming the global row.
          auto_toggle_bufferline = false,
          persist_buffer_sort = true,
          hover = { enabled = false },
          -- Route tab clicks to the centre editor even when focus is in the
          -- file tree or a Codex terminal; bufferline's default `buffer %d`
          -- would replace that panel and make it disappear.
          left_mouse_command = open_bufferline_buffer,
          close_command = close_buffer,
          right_mouse_command = close_buffer,
          -- A middle click on a file tab means close.  Calling the same safe
          -- handler as the visible ×/right-click keeps NvimTree and Codex
          -- panes intact instead of running `:tab sbuffer` in whichever pane
          -- happened to have focus.
          middle_mouse_command = close_buffer,
          custom_filter = function(bufnr)
            if not vim.api.nvim_buf_is_valid(bufnr) then
              return false
            end
            local buftype = vim.bo[bufnr].buftype
            local filetype = vim.bo[bufnr].filetype
            -- codex.nvim's pending proposal buffer is converted from
            -- acwrite to a normal listed buffer by the inline adapter so
            -- it can appear as the requested centre-editor tab.
            local is_codex_inline = vim.b[bufnr].personal_codex_diff == true
            return (buftype == "" or is_codex_inline)
              and not vim.tbl_contains({
                "NvimTree",
                "DiffviewFiles",
                "DiffviewFilePanel",
                "DiffviewFileHistory",
                "codecompanion",
                "Trouble",
                "qf",
                "help",
                "lazy",
                "notify",
              }, filetype)
          end,
          offsets = {
            {
              filetype = "NvimTree",
              text = " Dosyalar ",
              highlight = "Directory",
              separator = true,
              text_align = "center",
            },
          },
        },
      }
    end,
    config = function(_, opts)
      require("bufferline").setup(opts)
      -- One stable top row for F1/F2/... controls.  The file tabs are rendered
      -- by NvimControlBar() in the centre editor's winbar, so they can never
      -- push the controls underneath themselves again.
      vim.o.showtabline = 2
      vim.o.tabline = "%{%v:lua.NvimTopHeader()%}"
      vim.schedule(function()
        pcall(vim.cmd, "redrawtabline")
      end)
    end,
  },

  {
    "echasnovski/mini.nvim",
    version = false,
    event = "VeryLazy",
    config = function()
      require("mini.icons").setup({ style = "glyph" })
      require("mini.statusline").setup({ use_icons = true })
      -- Keep Codex reviews in one real editor buffer.  The overlay renders
      -- current additions in DiffAdd/green and reference deletions in
      -- DiffDelete/red without opening a side-by-side Diffview split.
      setup_mini_diff(require("mini.diff"))
      require("mini.comment").setup()
      require("mini.pairs").setup()
      require("mini.indentscope").setup({
        draw = { delay = 0 },
        symbol = "│",
        options = { try_as_border = true },
      })
    end,
  },

  {
    "folke/trouble.nvim",
    cmd = "Trouble",
    opts = {
      auto_close = false,
      auto_preview = true,
      focus = true,
      follow = true,
      win = { position = "bottom", size = 10 },
    },
    keys = {
      { "<leader>xx", "<cmd>Trouble diagnostics toggle<cr>", desc = "Tanıları Trouble'da göster" },
      { "<leader>xq", "<cmd>Trouble qflist toggle<cr>", desc = "Quickfix'i Trouble'da göster" },
      { "<leader>xs", "<cmd>Trouble symbols toggle focus=false<cr>", desc = "Sembol ağacını göster" },
      { "<leader>xl", "<cmd>Trouble loclist toggle<cr>", desc = "Loclist'i Trouble'da göster" },
    },
  },

  {
    "lalitmee/browse.nvim",
    cmd = "Browse",
    dependencies = { "folke/snacks.nvim" },
    opts = {
      -- Snacks is already part of the Codex terminal stack, so no second
      -- picker UI (and no Telescope startup cost) is needed.
      picker = "snacks",
      provider = "google",
      layouts = {
        browse = "dropdown",
        manual_bookmarks = "dropdown",
      },
      browser_bookmarks = {
        enabled = true,
        auto_detect = true,
        browsers = {
          chrome = true,
          safari = true,
          firefox = true,
          edge = true,
        },
        group_by_folder = true,
      },
    },
    keys = {
      { "<leader>bb", "<cmd>Browse<cr>", mode = { "n", "v" }, desc = "Browser/search menüsü" },
      { "<leader>bm", "<cmd>Browse bookmarks_browser<cr>", desc = "Tarayıcı yer imleri" },
    },
  },

  {
    "nvim-tree/nvim-tree.lua",
    version = "*",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      require("nvim-tree").setup({
        filesystem_watchers = {
          enable = true,
          debounce_delay = 50,
        },
        sort = { sorter = "case_sensitive" },
        view = {
          width = 34,
          side = "left",
          preserve_window_proportions = true,
        },
        renderer = {
          group_empty = true,
          highlight_git = true,
        },
        on_attach = function(bufnr)
          local api = require("nvim-tree.api")

          -- Keep all built-in nvim-tree mappings and add a centered media
          -- preview for the file under the cursor.  Glimpse handles images,
          -- PDFs, video frames and other non-text formats; source files stay
          -- in the normal editor window with Treesitter highlighting.
          api.map.on_attach.default(bufnr)
          local last_open_path
          local last_open_at = 0
          local preview_inflight = {}

          local function glimpse_for_node(node)
            if not node or not node.absolute_path or vim.fn.isdirectory(node.absolute_path) == 1 then
              return false
            end

            if not is_glimpse_candidate(node.absolute_path) then
              return false
            end

            local ok, glimpse = pcall(require, "glimpse")
            if not ok then
              return false, "missing"
            end
            -- `can_preview` also includes Glimpse's binary fallback (xxd/file),
            -- while `is_previewable` intentionally only covers the richer
            -- media/document helpers.
            local can_preview_ok, can_preview = false, false
            if type(glimpse.can_preview) == "function" then
              can_preview_ok, can_preview = pcall(glimpse.can_preview, node.absolute_path)
            end
            if not can_preview_ok or not can_preview then
              return false
            end

            -- A double click produces both mouse events.  Avoid starting two
            -- ImageMagick/ffmpeg jobs for the same media file while still
            -- allowing the file to be previewed again after a short pause.
            if preview_inflight[node.absolute_path] then
              return true
            end
            preview_inflight[node.absolute_path] = true
            vim.defer_fn(function()
              preview_inflight[node.absolute_path] = nil
            end, 900)

            local kind_ok, preview_kind = pcall(glimpse.get_preview_kind, node.absolute_path)
            if not kind_ok then
              preview_inflight[node.absolute_path] = nil
              return false
            end
            local tree_win = vim.api.nvim_get_current_win()
            local windows_before = {}
            for _, win in ipairs(vim.api.nvim_list_wins()) do
              windows_before[win] = true
            end
            local preview_ok = pcall(glimpse.preview, node.absolute_path, { window = "float" })
            if not preview_ok then
              preview_inflight[node.absolute_path] = nil
              return false
            end

            -- Image/video previews are rendered in a dedicated editor split.
            -- Focus that split so the file is immediately visible and video
            -- controls (<CR>, h/l) work after a single mouse click. Video
            -- extraction is asynchronous and uses a virtual buffer name, so
            -- retry briefly and identify a newly-created image window when a
            -- filepath lookup is not available yet.
            focus_glimpse_preview(node.absolute_path, preview_kind, tree_win, windows_before)
            return true
          end

          local function open_node(node, opener)
            if not node or not node.absolute_path then
              return
            end

            local now = uv.hrtime() / 1e6
            if node.absolute_path == last_open_path and now - last_open_at < 350 then
              return
            end
            last_open_path = node.absolute_path
            last_open_at = now

            -- Modifier clicks explicitly request another layout.  Honour that
            -- choice even for a media file; the normal click remains the
            -- centered Glimpse preview path.
            if opener then
              opener(node)
            elseif not glimpse_for_node(node) then
              (opener or api.node.open.edit)(node)
            end
          end

          -- Mouse release can arrive before nvim-tree has moved its cursor to
          -- the clicked row.  Deferring by one event-loop tick fixes the
          -- occasional wrong-file/no-file opening reported by users.
          local function open_after_mouse(opener)
            vim.defer_fn(function()
              if not vim.api.nvim_buf_is_valid(bufnr) then
                return
              end
              local ok, node = pcall(api.tree.get_node_under_cursor)
              if ok and node then
                open_node(node, opener)
              end
            end, 10)
          end

          -- A single click opens after the cursor has settled.  The same
          -- guarded callback handles the stock double-click event, so the two
          -- events cannot open a file or start a media renderer twice.
          vim.keymap.set("n", "<LeftRelease>", function()
            open_after_mouse()
          end, {
            buffer = bufnr,
            silent = true,
            nowait = true,
            desc = "Dosyayı editör penceresinde aç",
          })
          vim.keymap.set("n", "<2-LeftMouse>", function()
            open_after_mouse()
          end, {
            buffer = bufnr,
            silent = true,
            nowait = true,
            desc = "Dosyayı aç veya medyayı önizle",
          })

          -- Familiar desktop-style modifiers: middle click opens a new tab,
          -- Ctrl-click a vertical split, Shift-click a horizontal split.  A
          -- right click shows the selected node's information without making
          -- destructive changes; the existing double-right-click CD mapping
          -- remains intact.
          vim.keymap.set("n", "<MiddleMouse>", function()
            open_after_mouse(api.node.open.tab)
          end, { buffer = bufnr, silent = true, nowait = true, desc = "Dosyayı yeni sekmede aç" })
          vim.keymap.set("n", "<C-LeftMouse>", function()
            open_after_mouse(api.node.open.vertical)
          end, { buffer = bufnr, silent = true, nowait = true, desc = "Dosyayı dikey bölmede aç" })
          vim.keymap.set("n", "<S-LeftMouse>", function()
            open_after_mouse(api.node.open.horizontal)
          end, { buffer = bufnr, silent = true, nowait = true, desc = "Dosyayı yatay bölmede aç" })
          vim.keymap.set("n", "<RightMouse>", function()
            vim.defer_fn(function()
              if vim.api.nvim_buf_is_valid(bufnr) then
                pcall(api.node.show_info_popup)
              end
            end, 10)
          end, { buffer = bufnr, silent = true, nowait = true, desc = "Dosya bilgilerini göster" })
          vim.keymap.set("n", "<leader>p", function()
            local node = api.tree.get_node_under_cursor()
            local previewed, reason = glimpse_for_node(node)
            if not previewed and reason == "missing" then
              vim.notify("Glimpse henüz yüklenmedi; :Lazy load glimpse.nvim çalıştırın", vim.log.levels.WARN)
            end
          end, {
            buffer = bufnr,
            silent = true,
            nowait = true,
            desc = "Glimpse: dosya/medya önizleme",
          })
          -- `x` is the close affordance for the tree/panel in this desktop
          -- layout.  It intentionally replaces nvim-tree's cut mapping so a
          -- casual click/keypress cannot move a file by accident.
          vim.keymap.set("n", "x", function()
            pcall(vim.cmd, "NvimTreeClose")
          end, { buffer = bufnr, silent = true, nowait = true, desc = "Dosya ağacını kapat" })
        end,
        update_focused_file = {
          enable = true,
          -- Keep the tree rooted at the directory chosen by the user rather
          -- than changing it on every file open.
          update_root = false,
        },
        actions = {
          open_file = {
            -- Always send a file to a normal editor window.  If the only
            -- other window is Codex's terminal, create an editor split next
            -- to the tree instead of trying to edit the terminal buffer.
            window_picker = {
              enable = true,
              picker = function()
                local view = require("nvim-tree.view")
                local tree_win = view.get_winnr()
                local lib = require("nvim-tree.lib")

                local function is_editor_window(win)
                  if not vim.api.nvim_win_is_valid(win) or win == tree_win then
                    return false
                  end

                  local cfg = vim.api.nvim_win_get_config(win)
                  if cfg.relative ~= "" or not cfg.focusable or cfg.hide or cfg.external then
                    return false
                  end

                  local buf = vim.api.nvim_win_get_buf(win)
                  local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })
                  local filetype = vim.api.nvim_get_option_value("filetype", { buf = buf })
                  -- Keep terminal, help, quickfix and diff panes out of the
                  -- target list; they are viewers, not editing surfaces.
                  return buftype == ""
                    and not vim.tbl_contains({ "help", "qf", "diff", "notify", "lazy" }, filetype)
                end

                -- Prefer the window remembered by nvim-tree, then any normal
                -- editor window already present in this tab.
                if lib.target_winid and is_editor_window(lib.target_winid) then
                  return lib.target_winid
                end
                for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                  if is_editor_window(win) then
                    return win
                  end
                end

                -- Tree + Codex terminal is a common startup layout.  Split
                -- from the tree so the new editor pane lands between them.
                vim.cmd("belowright vsplit")
                return vim.api.nvim_get_current_win()
              end,
            },
          },
        },
        git = {
          enable = true,
          ignore = true,
        },
        filters = { dotfiles = false },
      })
    end,
  },

  {
    "lewis6991/gitsigns.nvim",
    event = { "BufReadPre", "BufNewFile" },
    opts = {
      signs = {
        add = { text = "│" },
        change = { text = "│" },
        delete = { text = "_" },
        topdelete = { text = "‾" },
        changedelete = { text = "~" },
      },
      signs_staged_enable = true,
      current_line_blame = false,
      -- Word-level diffing calls the built-in xdl diff engine while every
      -- decorated line is drawn.  On generated JSON/lock files that can peg
      -- an embedded Neovim process at 100% CPU.  Line-level signs still show
      -- the change without making the editor unresponsive.
      word_diff = false,
      max_file_length = 30000,
      update_debounce = 100,
      on_attach = function(buffer)
        local path = vim.api.nvim_buf_get_name(buffer)
        local stat = path ~= "" and uv.fs_stat(path) or nil
        -- Keep gitsigns useful for source files while skipping very large
        -- generated artifacts.  Diffview remains available explicitly for a
        -- file the user chooses, but opening it cannot silently start a
        -- background word-diff job for hundreds of megabytes.
        if stat and stat.size > 512 * 1024 then
          return false
        end

        local gs = require("gitsigns")
        local function map(mode, lhs, rhs, description, extra)
          local options = {
            buffer = buffer,
            desc = description,
            silent = true,
          }
          if extra then
            options = vim.tbl_extend("force", options, extra)
          end
          vim.keymap.set(mode, lhs, rhs, options)
        end

        map("n", "]c", function()
          if vim.wo.diff then
            return "]c"
          end
          vim.schedule(function()
            gs.next_hunk()
          end)
          return "<Ignore>"
        end, "Sonraki değişen hunk", { expr = true })
        map("n", "[c", function()
          if vim.wo.diff then
            return "[c"
          end
          vim.schedule(function()
            gs.prev_hunk()
          end)
          return "<Ignore>"
        end, "Önceki değişen hunk", { expr = true })
        map("n", "<leader>gp", gs.preview_hunk_inline, "Hunk'ı satır içinde önizle")
        map("n", "<leader>gP", gs.preview_hunk, "Hunk'ı floating pencerede önizle")
        map("n", "<leader>gs", gs.stage_hunk, "Hunk'ı stage et")
        map("n", "<leader>gr", gs.reset_hunk, "Hunk'ı geri al")
        map("v", "<leader>gs", function()
          gs.stage_hunk({ vim.fn.line("."), vim.fn.line("v") })
        end, "Seçimi stage et")
        map("v", "<leader>gr", function()
          gs.reset_hunk({ vim.fn.line("."), vim.fn.line("v") })
        end, "Seçimi geri al")
      end,
    },
  },

  {
    "sindrets/diffview.nvim",
    cmd = {
      "DiffviewOpen",
      "DiffviewClose",
      "DiffviewRefresh",
      "DiffviewFileHistory",
    },
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = {
      enhanced_diff_hl = true,
      use_icons = true,
      view = {
        merge_tool = { layout = "diff3_horizontal" },
      },
    },
  },

  {
    "adriancmiranda/glimpse.nvim",
    -- It is intentionally eager: a first mouse click on an image/video must
    -- be previewable even when the tree is opened immediately after startup.
    lazy = false,
    opts = {
      strategy = "auto",
      auto_open = false,
      auto_refresh = true,
      -- The user's local recordings can exceed Glimpse's conservative 50 MiB
      -- default.  Keep processing local-only, but allow normal phone/screen
      -- recordings to reach the previewer.
      safety = {
        max_file_size = 512 * 1024 * 1024,
      },
      -- Nvim-tree is wired above; avoid installing integrations for explorers
      -- that are not part of this setup while retaining Glimpse's standalone
      -- :GlimpsePreview command.
      integrations = {
        oil = { enable = false },
        neotree = { enable = false },
        telescope = { enable = false },
      },
    },
  },

  {
    "olimorris/codecompanion.nvim",
    event = "VeryLazy",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-treesitter/nvim-treesitter",
    },
    opts = function()
      local codex_path = vim.fn.exepath("codex")
      if codex_path == "" then
        codex_path = "codex"
      end

      local codex_model = vim.env.CODEX_MODEL or "gpt-5.6-sol"
      local codex_thought_level = vim.env.CODEX_THOUGHT_LEVEL or "ultra"

      local codex_acp_path = vim.fn.exepath("codex-acp")
      local codex_acp_command
      if codex_acp_path ~= "" then
        codex_acp_command = { codex_acp_path }
      else
        -- The globally installed binary is preferred. This is only a
        -- fallback for a fresh machine where npm can fetch the adapter.
        codex_acp_command = { "npx", "-y", "@agentclientprotocol/codex-acp" }
      end

      -- Keep machine-specific provider endpoints out of the public config.
      -- An explicit environment variable wins; otherwise reuse the local
      -- Codex config when it has an oceanapi section, and fall back to the
      -- public OpenAI-compatible endpoint for a fresh installation.
      local function resolve_codex_oceanapi_base_url()
        local explicit = vim.env.CODEX_OCEANAPI_BASE_URL
        if explicit and vim.trim(explicit) ~= "" then
          return vim.trim(explicit):gsub("/+$", "")
        end

        local config_path = vim.fn.expand("~/.codex/config.toml")
        local ok, lines = pcall(vim.fn.readfile, config_path)
        if ok and type(lines) == "table" then
          local in_oceanapi_section = false
          for _, line in ipairs(lines) do
            local section = line:match("^%s*%[([^%]]+)%]")
            if section then
              in_oceanapi_section = section == "model_providers.oceanapi"
            elseif in_oceanapi_section then
              local value = line:match('^%s*base_url%s*=%s*"([^"]+)"')
                or line:match("^%s*base_url%s*=%s*'([^']+)'")
              if value and value ~= "" then
                return value:gsub("/+$", "")
              end
            end
          end
        end
        return "https://api.openai.com/v1"
      end

      local codex_oceanapi_base_url = resolve_codex_oceanapi_base_url()

      local codex_acp_config = vim.env.CODEX_ACP_CONFIG
      if not codex_acp_config or codex_acp_config == "" then
        codex_acp_config = vim.json.encode({
          model = codex_model,
          model_provider = vim.env.CODEX_MODEL_PROVIDER or "oceanapi",
          model_providers = {
            oceanapi = {
              name = "OceanAPI",
              base_url = codex_oceanapi_base_url,
              wire_api = "responses",
              env_key = "OCEANAPI_API_KEY",
              requires_openai_auth = true,
            },
          },
          approval_policy = "never",
          sandbox_mode = "danger-full-access",
        })
      end

      return {
        -- Keep ACP MCP support enabled; servers can be added here later and
        -- will then be forwarded to the Codex session.
        mcp = {
          opts = {
            acp_enabled = true,
          },
        },
        adapters = {
          acp = {
            codex = function()
              return require("codecompanion.adapters").extend("codex", {
                commands = { default = codex_acp_command },
                defaults = {
                  -- Reuse the existing Codex/ChatGPT login; do not require
                  -- a second OpenAI API key just to open a Neovim chat.
                  auth_method = "chat-gpt",
                  session_config_options = {
                    model = codex_model,
                    -- ACP exposes this as the `thought_level` category
                    -- (the underlying option id is `reasoning_effort`).
                    thought_level = codex_thought_level,
                    mode = "agent-full-access",
                  },
                  mcpServers = "inherit_from_config",
                },
                env = {
                  CODEX_PATH = codex_path,
                  CODEX_CONFIG = codex_acp_config,
                  MODEL_PROVIDER = vim.env.CODEX_MODEL_PROVIDER or "oceanapi",
                },
              })
            end,
          },
          http = {
            -- Inline transformations currently support HTTP adapters only.
            -- Point them at the same OpenAI-compatible gateway used by the
            -- user's Codex CLI, while chat/review use ACP above.
            oceanapi = function()
              return require("codecompanion.adapters").extend("openai_responses", {
                name = "oceanapi",
                formatted_name = "OceanAPI",
                url = vim.env.CODECOMPANION_OCEANAPI_URL
                  or (codex_oceanapi_base_url .. "/responses"),
                env = { api_key = "OCEANAPI_API_KEY" },
                schema = {
                  model = { default = vim.env.CODECOMPANION_MODEL or "gpt-5.6-sol" },
                },
              })
            end,
          },
        },
        interactions = {
          chat = {
            adapter = "codex",
            opts = {
              completion_provider = "default",
            },
          },
          inline = {
            adapter = "oceanapi",
          },
        },
        display = {
          action_palette = {
            provider = "default",
          },
          chat = {
          window = {
            layout = "vertical",
            position = "right",
            width = 0.40,
            border = "rounded",
            -- Each editor tab keeps its own Codex chat.  Opening a second
            -- chat no longer steals or hides the first agent's conversation.
            pertab = true,
          },
            start_in_insert_mode = false,
            show_token_count = true,
          },
          diff = {
            enabled = true,
            layout = "vertical",
          },
        },
        opts = {
          log_level = "WARN",
          language = "Turkish",
        },
      }
    end,
    config = function(_, opts)
      local codecompanion = require("codecompanion")
      codecompanion.setup(opts)
    end,
    keys = {
      {
        "<leader>ai",
        "<cmd>CodeCompanionActions<cr>",
        mode = { "n", "v" },
        desc = "CodeCompanion action palette",
      },
      {
        "<leader>ac",
        "<cmd>CodeCompanionChat Toggle<cr>",
        mode = { "n", "v" },
        desc = "CodeCompanion Codex sohbeti",
      },
      {
        "<leader>ae",
        "<cmd>CodeCompanion<cr>",
        mode = { "n", "v" },
        desc = "Seçimi CodeCompanion ile düzenle",
      },
      {
        "<leader>ar",
        "<cmd>CodeCompanionCodeReview<cr>",
        mode = "n",
        desc = "Değişiklikleri CodeCompanion ile incele",
      },
      {
        "<leader>am",
        "<cmd>CodeCompanionChat Changes<cr>",
        mode = "n",
        desc = "CodeCompanion'ın değiştirdiği dosyalar",
      },
      {
        "<leader>ax",
        "<cmd>CodeCompanion /explain<cr>",
        mode = "v",
        desc = "Seçili kodu açıkla",
      },
      {
        "<leader>af",
        "<cmd>CodeCompanion /fix<cr>",
        mode = "v",
        desc = "Seçili kodu düzelt",
      },
      {
        "<leader>at",
        "<cmd>CodeCompanion /tests<cr>",
        mode = "v",
        desc = "Seçili kod için test yaz",
      },
      {
        "<leader>al",
        "<cmd>CodeCompanion /lsp<cr>",
        mode = "v",
        desc = "Seçili kodun LSP tanılarını açıkla",
      },
    },
  },

  {
    "ishiooon/codex.nvim",
    -- The terminal is part of the startup layout, so load the integration
    -- before VimEnter instead of waiting for the VeryLazy event.
    lazy = false,
    dependencies = { "folke/snacks.nvim" },
    opts = function()
      local codex = vim.fn.exepath("codex")
      if codex == "" then
        codex = "codex"
      end

      -- Multiple Neovim processes can start in the same second.  codex.nvim
      -- otherwise seeds its random port picker with os.time(), which makes
      -- those processes choose the same port and report EADDRINUSE.  A
      -- process-specific range keeps the ACP server isolated while retaining
      -- the plugin's normal port discovery/retry behavior.
      local port_min = 10000 + (vim.fn.getpid() % 50000)
      local port_max = math.min(port_min + 999, 65535)

      return {
        terminal_cmd = codex,
        auto_start = true,
        auth_mode = "optional",
        fallback_to_terminal_send = true,
        focus_after_send = false,
        port_range = { min = port_min, max = port_max },
        env = {
          ENABLE_IDE_INTEGRATION = "true",
          FORCE_CODE_TERMINAL = "true",
        },
        terminal = {
          provider = "auto",
          split_side = "right",
          split_width_percentage = 0.34,
          git_repo_cwd = true,
          -- Keep Codex rooted in the current Neovim working directory. The
          -- file tree is only a view; the normal `:pwd` is the single
          -- source of truth for the Codex process.
          cwd_provider = function()
            return vim.fn.getcwd()
          end,
          unfocus_key = "<C-]>",
        },
        diff_opts = {
          layout = "vertical",
          open_in_new_tab = false,
          keep_terminal_focus = false,
          hide_terminal_in_new_tab = false,
          on_new_file_reject = "keep_empty",
        },
        -- Kısayolları aşağıdaki `keys` bölümünde tekil olarak yönetiyoruz.
        keymaps = { enabled = false },
      }
    end,
    config = function(_, opts)
      require("codex").setup(opts)
      install_codex_yolo_diff_wrapper()
    end,
    keys = {
      {
        "<leader>cc",
        "<cmd>Codex<cr>",
        mode = "n",
        desc = "Codex terminalini aç/kapat",
      },
      {
        "<leader>cf",
        "<cmd>CodexFocus<cr>",
        mode = "n",
        desc = "Codex terminaline odaklan",
      },
      {
        "<leader>cm",
        "<cmd>CodexMaximizeToggle<cr>",
        mode = "n",
        desc = "Codex terminalini büyüt/küçült",
      },
      {
        "<leader>cs",
        "<cmd>CodexSend<cr>",
        mode = "v",
        desc = "Seçimi Codex'e gönder",
      },
      {
        "<leader>ca",
        "<cmd>CodexDiffAccept<cr>",
        mode = "n",
        desc = "Codex diff'ini kabul et",
      },
      {
        "<leader>cx",
        "<cmd>CodexDiffDeny<cr>",
        mode = "n",
        desc = "Codex diff'ini reddet",
      },
    },
  },
}, {
  change_detection = { notify = false },
  checker = { enabled = false },
  install = { colorscheme = { "habamax" } },
  -- Bu kurulumdaki eklentilerin hiçbiri LuaRocks gerektirmiyor; eksik
  -- hererocks uyarısını ve gereksiz ağ kurulumunu kapat.
  rocks = { enabled = false },
  ui = { border = "rounded" },
  -- Kullanılmayan yerleşik vim eklentilerini runtime path'ten çıkar; hem
  -- açılış süresi hem de rtp tarama maliyeti düşer.
  performance = {
    rtp = {
      disabled_plugins = {
        "gzip",
        "tarPlugin",
        "tohtml",
        "tutor",
        "zipPlugin",
        "rplugin",
      },
    },
  },
})
