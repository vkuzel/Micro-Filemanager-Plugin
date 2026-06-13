VERSION = "3.5.1"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local buffer = import("micro/buffer")
local os = import("os")
local filepath = import("path/filepath")

local function io_path_exists(path)
	local file_stat, stat_err = os.Stat(path)
	if stat_err ~= nil then
		return os.IsExist(stat_err)
	elseif file_stat ~= nil then
		return true
	end
	return false
end

local function io_is_dir(path)
	local file_info, stat_error = os.Stat(path)
	if file_info ~= nil then
		return file_info:IsDir()
	else
		micro.InfoBar():Error("Error checking if is dir: ", stat_error)
		return nil
	end
end

local function io_create_path(base_path, path_text)
	local function split_path(path_text)
		local sep = "/"
		local parts, start = {}, 1
		while true do
		local i = string.find(path_text, sep, start, true)
		if not i then
			parts[#parts + 1] = string.sub(path_text, start)
			break
		end
		parts[#parts + 1] = string.sub(path_text, start, i - 1)
		start = i + #sep
		end
		return parts
	end

	local full_path = base_path

	local path_parts = split_path(path_text)
	for i, part in ipairs(path_parts) do
		local is_dir = i ~= #path_parts
		if is_dir and part ~= "" then
			full_path = filepath.Join(full_path, part)
			if not io_path_exists(full_path) then
				os.Mkdir(full_path, os.ModePerm)
				micro.Log("Filemanager created directory: " .. full_path)
			end
		elseif not is_dir and part ~= "" then
			full_path = filepath.Join(full_path, part)
			if not io_path_exists(full_path) then
				os.Create(full_path)
				micro.Log("Filemanager created file: " .. full_path)
			end
		end
	end

	return full_path
end

-- Clear out all stuff in Micro's messenger
local function clear_messenger()
	-- messenger:Reset()
	-- messenger:Clear()
end

-- Holds the micro.CurPane() we're manipulating
local tree_view = nil
-- Keeps track of the current working directory
local current_dir = os.Getwd()
-- Keep track of current highest visible indent to resize width appropriately
local highest_visible_indent = 0
-- Holds a table of paths -- objects from new_listobj() calls
local scanlist = {}

-- Get a new object used when adding to scanlist
local function new_listobj(p, d, o, i)
	return {
		["abspath"] = p,
		["dirmsg"] = d,
		["owner"] = o,
		["indent"] = i,
		-- Since decreasing/increasing is common, we include these with the object
		["decrease_owner"] = function(self, minus_num)
			self.owner = self.owner - minus_num
		end,
		["increase_owner"] = function(self, plus_num)
			self.owner = self.owner + plus_num
		end
	}
end

-- Repeats a string x times, then returns it concatenated into one string
local function repeat_str(str, len)
	-- Do NOT try to concat in a loop, it freezes micro...
	-- instead, use a temporary table to hold values
	local string_table = {}
	for i = 1, len do
		string_table[i] = str
	end
	-- Return the single string of repeated characters
	return table.concat(string_table)
end


-- Returns a list of files (in the target dir) that are ignored by the VCS system (if exists)
-- aka this returns a list of gitignored files (but for whatever VCS is found)
local function get_ignored_files(tar_dir)
	-- True/false if the target dir returns a non-fatal error when checked with 'git status'
	local function has_git()
		local git_rp_results = shell.ExecCommand('git  -C "' .. tar_dir .. '" rev-parse --is-inside-work-tree')
		return git_rp_results:match("^true%s*$")
	end
	local readout_results = {}
	-- TODO: Support more than just Git, such as Mercurial or SVN
	if has_git() then
		-- If the dir is a git dir, get all ignored in the dir
		local git_ls_results =
			shell.ExecCommand('git -C "' .. tar_dir .. '" ls-files . --ignored --exclude-standard --others --directory')
		-- Cut off the newline that is at the end of each result
		for split_results in string.gmatch(git_ls_results, "([^\r\n]+)") do
			-- git ls-files adds a trailing slash if it's a dir, so we remove it (if it is one)
			readout_results[#readout_results + 1] =
				(string.sub(split_results, -1) == "/" and string.sub(split_results, 1, -2) or split_results)
		end
	end

	-- Make sure we return a table
	return readout_results
end

-- Returns the basename of a path (aka a name without leading path)
local function get_basename(path)
	if path == nil then
		micro.Log("Bad path passed to get_basename")
		return nil
	else
		-- Get Go's path lib for a basename callback
		local golib_path = import("filepath")
		return golib_path.Base(path)
	end
end

-- Structures the output of the scanned directory content to be used in the scanlist table
-- This is useful for both initial creation of the tree, and when nesting with uncompress_target()
local function get_scanlist(dir, ownership, indent_n)
	local golib_ioutil = import("ioutil")
	-- Gets a list of all the files in the current dir
	local dir_scan, scan_error = golib_ioutil.ReadDir(dir)

	-- dir_scan will be nil if the directory is read-protected (no permissions)
	if dir_scan == nil then
		micro.InfoBar():Error("Error scanning dir: ", scan_error)
		return nil
	end

	-- The list of files to be returned (and eventually put in the view)
	local results = {}
	local files = {}

	local function get_results_object(file_name)
		local abs_path = filepath.Join(dir, file_name)
		-- Use "+" for dir's, "" for files
		local dirmsg = (io_is_dir(abs_path) and "+" or "")
		return new_listobj(abs_path, dirmsg, ownership, indent_n)
	end

	-- Save so we don't have to rerun GetOption a bunch
	local folders_first = config.GetGlobalOption("filemanager.foldersfirst")

	-- Hold the current scan's filename in most of the loops below
	local filename

	for i = 1, #dir_scan do
		filename = dir_scan[i]:Name()
		-- This file is good to show, proceed
		if folders_first and not io_is_dir(filepath.Join(dir, filename)) then
			-- If folders_first and this is a file, add it to (temporary) files
			files[#files + 1] = get_results_object(filename)
		else
			-- Otherwise, add to results
			results[#results + 1] = get_results_object(filename)
		end
	end
	if #files > 0 then
		-- Append any files to results, now that all folders have been added
		-- files will be > 0 only if folders_first and there are files
		for i = 1, #files do
			results[#results + 1] = files[i]
		end
	end

	-- Return the list of scanned files
	return results
end

-- A short "get y" for when acting on the scanlist
-- Needed since we don't store the first 3 visible indicies in scanlist
local function get_safe_y(optional_y)
	-- Default to 0 so we can check against and see if it's bad
	local y = 0
	-- Make the passed y optional
	if optional_y == nil then
		-- Default to cursor's Y loc if nothing was passed, instead of declaring another y
		optional_y = tree_view.Cursor.Loc.Y
	end
	-- 0/1/2 would be the top "dir, separator, .." so check if it's past
	if optional_y > 2 then
		-- -2 to conform to our scanlist, since zero-based Go index & Lua's one-based
		y = tree_view.Cursor.Loc.Y - 2
	end
	return y
end

-- Hightlights the line when you move the cursor up/down
local function select_line(last_y)
	-- Make last_y optional
	if last_y ~= nil then
		-- Don't let them move past ".." by checking the result first
		if last_y > 1 then
			-- If the last position was valid, move back to it
			tree_view.Cursor.Loc.Y = last_y
		end
	elseif tree_view.Cursor.Loc.Y < 2 then
		-- Put the cursor on the ".." if it's above it
		tree_view.Cursor.Loc.Y = 2
	end

	-- Puts the cursor back in bounds (if it isn't) for safety
	tree_view.Cursor:Relocate()

	-- Makes sure the cursor is visible (if it isn't)
	-- (false) means no callback
	tree_view:Center()

	-- Highlight the current line where the cursor is
	tree_view.Cursor:SelectLine()
end

-- Simple true/false if scanlist is currently empty
local function scanlist_is_empty()
	if next(scanlist) == nil then
		return true
	else
		return false
	end
end

local function refresh_view()
	clear_messenger()

	-- If it's less than 30, just use 30 for width. Don't want it too small

	if tree_view:GetView().Width < 30 then
		tree_view:ResizePane(30)
	end

	-- Delete everything in the view/buffer
	tree_view.Buf.EventHandler:Remove(tree_view.Buf:Start(), tree_view.Buf:End())

	-- Insert the top 3 things that are always there
	-- Current dir
	tree_view.Buf.EventHandler:Insert(buffer.Loc(0, 0), current_dir .. "\n")
	-- An ASCII separator
	tree_view.Buf.EventHandler:Insert(buffer.Loc(0, 1), repeat_str("─", tree_view:GetView().Width) .. "\n")
	-- The ".." and use a newline if there are things in the current dir
	tree_view.Buf.EventHandler:Insert(buffer.Loc(0, 2), (#scanlist > 0 and "..\n" or ".."))

	-- Holds the current basename of the path (purely for display)
	local display_content

	-- NOTE: might want to not do all these concats in the loop, it can get slow
	for i = 1, #scanlist do
		-- The first 3 indicies are the dir/separator/"..", so skip them
		if scanlist[i].dirmsg ~= "" then
			-- Add the + or - to the left to signify if it's compressed or not
			-- Add a forward slash to the right to signify it's a dir
			display_content = scanlist[i].dirmsg .. " " .. get_basename(scanlist[i].abspath) .. "/"
		else
			-- Use the basename from the full path for display
			-- Two spaces to align with any directories, instead of being "off"
			display_content = "  " .. get_basename(scanlist[i].abspath)
		end

		if scanlist[i].owner > 0 then
			-- Add a space and repeat it * the indent number
			display_content = repeat_str(" ", 2 * scanlist[i].indent) .. display_content
		end

		-- Newlines are needed for all inserts except the last
		-- If you insert a newline on the last, it leaves a blank spot at the bottom
		if i < #scanlist then
			display_content = display_content .. "\n"
		end

		-- Insert line-by-line to avoid out-of-bounds on big folders
		-- +2 so we skip the 0/1/2 positions that hold the top dir/separator/..
		tree_view.Buf.EventHandler:Insert(buffer.Loc(0, i + 2), display_content)
	end

	-- Resizes all views after messing with ours
    tree_view:Tab():Resize()
end

-- Moves the cursor to the ".." in tree_view
local function move_cursor_top()
	-- 2 is the position of the ".."
	tree_view.Cursor.Loc.Y = 2

	-- select the line after moving
	select_line()
end

local function refresh_and_select()
	-- Save the cursor position before messing with the view..
	-- because changing contents in the view causes the Y loc to move
	local last_y = tree_view.Cursor.Loc.Y
	-- Actually refresh
	refresh_view()
	-- Moves the cursor back to it's original position
	select_line(last_y)
end

-- Find everything nested under the target, and remove it from the scanlist
local function compress_target(y, delete_y)
	-- Can't compress the top stuff, or if there's nothing there, so exit early
	if y == 0 or scanlist_is_empty() then
		return
	end
	-- Check if the target is a dir, since files don't have anything to compress
	-- Also make sure it's actually an uncompressed dir by checking the gutter message
	if scanlist[y].dirmsg == "-" then
		local target_index, delete_index
		-- Add the original target y to stuff to delete
		local delete_under = {[1] = y}
		local new_table = {}
		local del_count = 0
		-- Loop through the whole table, looking for nested content, or stuff with ownership == y...
		-- and delete matches. y+1 because we want to start under y, without actually touching y itself.
		for i = 1, #scanlist do
			delete_index = false
			-- Don't run on y, since we don't always delete y
			if i ~= y then
				-- On each loop, check if the ownership matches
				for x = 1, #delete_under do
					-- Check for something belonging to a thing to delete
					if scanlist[i].owner == delete_under[x] then
						-- Delete the target if it has an ownership to our delete target
						delete_index = true
						-- Keep count of total deleted (can't use #delete_under because it's for deleted dir count)
						del_count = del_count + 1
						-- Check if an uncompressed dir
						if scanlist[i].dirmsg == "-" then
							-- Add the index to stuff to delete, since it holds nested content
							delete_under[#delete_under + 1] = i
						end
						-- See if we're on the "deepest" nested content
						if scanlist[i].indent == highest_visible_indent and scanlist[i].indent > 0 then
							-- Save the lower indent, since we're minimizing/deleting nested dirs
							highest_visible_indent = highest_visible_indent - 1
						end
						-- Nothing else to do, so break this inner loop
						break
					end
				end
			end
			if not delete_index then
				-- Save the index in our new table
				new_table[#new_table + 1] = scanlist[i]
			end
		end

		scanlist = new_table

		if del_count > 0 then
			-- Ownership adjusting since we're deleting an index
			for i = y + 1, #scanlist do
				-- Don't touch root file/dirs
				if scanlist[i].owner > y then
					-- Minus ownership, on everything below i, the number deleted
					scanlist[i]:decrease_owner(del_count)
				end
			end
		end

		-- If not deleting, then update the gutter message to be + to signify compressed
		if not delete_y then
			-- Update the dir message
			scanlist[y].dirmsg = "+"
		end
	elseif config.GetGlobalOption("filemanager.compressparent") and not delete_y then
		goto_parent_dir()
		-- Prevent a pointless refresh of the view
		return
	end

	-- Put outside check above because we call this to delete targets as well
	if delete_y then
		local second_table = {}
		-- Quickly remove y
		for i = 1, #scanlist do
			if i == y then
				-- Reduce everything's ownership by 1 after y
				for x = i + 1, #scanlist do
					-- Don't touch root file/dirs
					if scanlist[x].owner > y then
						-- Minus 1 since we're just deleting y
						scanlist[x]:decrease_owner(1)
					end
				end
			else
				-- Put everything but y into the temporary table
				second_table[#second_table + 1] = scanlist[i]
			end
		end
		-- Put everything (but y) back into scanlist, with adjusted ownership values
		scanlist = second_table
	end

	if tree_view:GetView().Width > (30 + highest_visible_indent) then
		-- Shave off some width
        tree_view:ResizePane(30 + highest_visible_indent)
	end

	refresh_and_select()
end

-- Changes the current dir in the top of the tree..
-- then scans that dir, and prints it to the view
local function update_current_dir(path)
	-- Clear the highest since this is a full refresh
	highest_visible_indent = 0
	-- Set the width back to 30
	tree_view:ResizePane(30)
	-- Update the current dir to the new path
	current_dir = path

	-- Get the current working dir's files into our list of files
	-- 0 ownership because this is a scan of the base dir
	-- 0 indent because this is the base dir
	local scan_results = get_scanlist(path, 0, 0)
	-- Safety check with not-nil
	if scan_results ~= nil then
		-- Put in the new scan stuff
		scanlist = scan_results
	else
		-- If nil, just empty it
		scanlist = {}
	end

	refresh_view()
	-- Since we're going into a new dir, move cursor to the ".." by default
	move_cursor_top()
end

-- (Tries to) go back one "step" from the current directory
local function go_back_dir()
	-- Use Micro's dirname to get everything but the current dir's path
	local one_back_dir = filepath.Dir(current_dir)
	-- Try opening, assuming they aren't at "root", by checking if it matches last dir
	if one_back_dir ~= current_dir then
		-- If filepath.Dir returns different, then they can move back..
		-- so we update the current dir and refresh
		update_current_dir(one_back_dir)
	end
end

local function open_path(path)
	-- Close all panes except for the tree view
	local tab = tree_view:Tab()
	local i = 1
	while #tab.Panes > 1 do
		pane = tab.Panes[i]
		if pane ~= tree_view then
			pane:Quit()
			i = 1
		else
			i = i + 1
		end
	end

	-- Replace tree view with the file
	local new_buf = buffer.NewBufferFromFile(path)
	tree_view:OpenBuffer(new_buf)
	tree_view = nil
	clear_messenger()
end

-- Tries to open the current index
-- If it's the top dir indicator, or separator, nothing happens
-- If it's ".." then it tries to go back a dir
-- If it's a dir then it moves into the dir and refreshes
-- If it's actually a file, open it in tree view
-- THIS EXPECTS ZERO-BASED Y
local function try_open_at_y(y)
	-- 2 is the zero-based index of ".."
	if y == 2 then
		go_back_dir()
	elseif y > 2 and not scanlist_is_empty() then
		-- -2 to conform to our scanlist "missing" first 3 indicies
		y = y - 2
		if scanlist[y].dirmsg ~= "" then
			-- if passed path is a directory, update the current dir to be one deeper..
			update_current_dir(scanlist[y].abspath)
		else
			-- If it's a file, then open it
			file_path = scanlist[y].abspath
			open_path(file_path)
			micro.InfoBar():Message("Filemanager opened ", file_path)
		end
	else
		micro.InfoBar():Error("Can't open that")
	end
end

-- Opens the dir's contents nested under itself
local function uncompress_target(y)
	-- Exit early if on the top 3 non-list items
	if y == 0 or scanlist_is_empty() then
		return
	end
	-- Only uncompress if it's a dir and it's not already uncompressed
	if scanlist[y].dirmsg == "+" then
		-- Get a new scanlist with results from the scan in the target dir
		local scan_results = get_scanlist(scanlist[y].abspath, y, scanlist[y].indent + 1)
		-- Don't run any of this if there's nothing in the dir we scanned, pointless
		if scan_results ~= nil then
			-- Will hold all the old values + new scan results
			local new_table = {}
			-- By not inserting in-place, some unexpected results can be avoided
			-- Also, table.insert actually moves values up (???) instead of down
			for i = 1, #scanlist do
				-- Put the current val into our new table
				new_table[#new_table + 1] = scanlist[i]
				if i == y then
					-- Fill in the scan results under y
					for x = 1, #scan_results do
						new_table[#new_table + 1] = scan_results[x]
					end
					-- Basically "moving down" everything below y, so ownership needs to increase on everything
					for inner_i = y + 1, #scanlist do
						-- When root not pushed by inserting, don't change its ownership
						-- This also has a dual-purpose to make it not effect root file/dirs
						-- since y is always >= 3
						if scanlist[inner_i].owner > y then
							-- Increase each indicies ownership by the number of scan results inserted
							scanlist[inner_i]:increase_owner(#scan_results)
						end
					end
				end
			end

			-- Update our scanlist with the new values
			scanlist = new_table
		end

		-- Change to minus to signify it's uncompressed
		scanlist[y].dirmsg = "-"

		-- Check if we actually need to resize, or if we're nesting at the same indent
		-- Also check if there's anything in the dir, as we don't need to expand on an empty dir
		if scan_results ~= nil then
			if scanlist[y].indent > highest_visible_indent and #scan_results >= 1 then
				-- Save the new highest indent
				highest_visible_indent = scanlist[y].indent
				-- Increase the width to fit the new nested content
				tree_view:ResizePane(tree_view:GetView().Width + scanlist[y].indent)
			end
		end

		refresh_and_select()
	end
end

-- Prompts the user for the file/dir name, then creates the file/dir using Go's os package
local function new_path(bp, args)
	local function base_path()
		-- The target they're trying to create on top of/in/at/whatever
		local y = get_safe_y()
		-- A true/false if scanlist is empty
		local scanlist_empty = scanlist_is_empty()
		if not scanlist_empty and y ~= 0 then
			-- If they're inserting on a folder, don't strip its path
			if scanlist[y].dirmsg ~= "" then
				-- Join our new file/dir onto the dir
				return scanlist[y].abspath
			else
				-- The current index is a file, so strip its name and join ours onto it
				return filepath.Dir(scanlist[y].abspath)
			end
		else
			-- if nothing in the list, or cursor is on top of "..", use the current dir
			return current_dir
		end
	end

	if micro.CurPane() ~= tree_view then
		micro.InfoBar():Message("You can't create a file/dir if your cursor isn't in the tree!")
		return
	end

	if #args ~= 1 then
		micro.InfoBar():Error('When using "create" you need to input a <path> as single argument')
		return
	end

	local base_path = base_path()
	local filedir_name = args[1]
	local filedir_path = io_create_path(base_path, filedir_name)

	-- If the file we tried to make doesn't exist, fail
	if not io_path_exists(filedir_path) then
		micro.InfoBar():Error("Filemanager creation failed: ", filedir_path)
		return
	end

	micro.InfoBar():Message("Filemanager created: ", filedir_path)
	open_path(filedir_path)
end

-- open_tree setup's the view
local function open_tree()
	-- Open a new Vsplit (on the very left)
	micro.CurPane():VSplitIndex(buffer.NewBuffer("", "filemanager"), false)
	-- Save the new view so we can access it later
	tree_view = micro.CurPane()

	-- Set the width of tree_view to 30% & lock it
    tree_view:ResizePane(30)
	-- Set the type to unsavable
    -- tree_view.Buf.Type = buffer.BTLog
    tree_view.Buf.Type.Scratch = true
    tree_view.Buf.Type.Readonly = true

	-- Set the various display settings, but only on our view (by using SetLocalOption instead of SetOption)
	-- NOTE: Micro requires the true/false to be a string
	-- Softwrap long strings (the file/dir paths)
    tree_view.Buf:SetOptionNative("softwrap", true)
    -- No line numbering
    tree_view.Buf:SetOptionNative("ruler", false)
    -- Is this needed with new non-savable settings from being "vtLog"?
    tree_view.Buf:SetOptionNative("autosave", false)
    -- Don't show the statusline to differentiate the view from normal views
    tree_view.Buf:SetOptionNative("statusformatr", "")
    tree_view.Buf:SetOptionNative("statusformatl", "filemanager")
    tree_view.Buf:SetOptionNative("scrollbar", false)

	-- Fill the scanlist, and then print its contents to tree_view
	update_current_dir(os.Getwd())
end

-- close_tree will close the tree plugin view and release memory.
local function close_tree()
	if tree_view ~= nil then
		tree_view:Quit()
		tree_view = nil
		clear_messenger()
	end
end

-- toggle_tree will toggle the tree view visible (create) and hide (delete).
function toggle_tree()
	if tree_view == nil then
		open_tree()
	else
		close_tree()
	end
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Functions exposed specifically for the user to bind
-- Some are used in callbacks as well
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

function uncompress_at_cursor()
	if micro.CurPane() == tree_view then
		uncompress_target(get_safe_y())
	end
end

function compress_at_cursor()
	if micro.CurPane() == tree_view then
		-- False to not delete y
		compress_target(get_safe_y(), false)
	end
end

-- Goes up 1 visible directory (if any)
-- Not local so it can be bound
function goto_prev_dir()
	if micro.CurPane() ~= tree_view or scanlist_is_empty() then
		return
	end

	local cur_y = get_safe_y()
	-- If they try to run it on the ".." do nothing
	if cur_y ~= 0 then
		local move_count = 0
		for i = cur_y - 1, 1, -1 do
			move_count = move_count + 1
			-- If a dir, stop counting
			if scanlist[i].dirmsg ~= "" then
				-- Jump to its parent (the ownership)
				tree_view.Cursor:UpN(move_count)
				select_line()
				break
			end
		end
	end
end

-- Goes down 1 visible directory (if any)
-- Not local so it can be bound
function goto_next_dir()
	if micro.CurPane() ~= tree_view or scanlist_is_empty() then
		return
	end

	local cur_y = get_safe_y()
	local move_count = 0
	-- If they try to goto_next on "..", pretends the cursor is valid
	if cur_y == 0 then
		cur_y = 1
		move_count = 1
	end
	-- Only do anything if it's even possible for there to be another dir
	if cur_y < #scanlist then
		for i = cur_y + 1, #scanlist do
			move_count = move_count + 1
			-- If a dir, stop counting
			if scanlist[i].dirmsg ~= "" then
				-- Jump to its parent (the ownership)
				tree_view.Cursor:DownN(move_count)
				select_line()
				break
			end
		end
	end
end

-- Goes to the parent directory (if any)
-- Not local so it can be keybound
function goto_parent_dir()
	if micro.CurPane() ~= tree_view or scanlist_is_empty() then
		return
	end

	local cur_y = get_safe_y()
	-- Check if the cursor is even in a valid location for jumping to the owner
	if cur_y > 0 then
		-- Jump to its parent (the ownership)
		tree_view.Cursor:UpN(cur_y - scanlist[cur_y].owner)
		select_line()
	end
end

function try_open_at_cursor()
	if micro.CurPane() ~= tree_view or scanlist_is_empty() then
		return
	end

	try_open_at_y(tree_view.Cursor.Loc.Y)
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Shorthand functions for actions to reduce repeat code
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Used to fail certain actions that we shouldn't allow on the tree_view
local function false_if_tree(view)
	if view == tree_view then
		return false
	end
end

-- Select the line at the cursor
local function selectline_if_tree(view)
	if view == tree_view then
		select_line()
	end
end

-- Move the cursor to the top, but don't allow the action
local function aftermove_if_tree(view)
	if view == tree_view then
		if tree_view.Cursor.Loc.Y < 2 then
			-- If it went past the "..", move back onto it
			tree_view.Cursor:DownN(2 - tree_view.Cursor.Loc.Y)
		end
		select_line()
	end
end

local function clearselection_if_tree(view)
	if view == tree_view then
		-- Clear the selection when doing a find, so it doesn't copy the current line
		tree_view.Cursor:ResetSelection()
	end
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- All the events for certain Micro keys go below here
-- Other than things we flat-out fail
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Close current
function preQuit(view)
	if view == tree_view then
		-- A fake quit function
		close_tree()
		-- Don't actually "quit", otherwise it closes everything without saving for some reason
		return false
	end
end

-- Close all
function preQuitAll(view)
	close_tree()
end

-- FIXME: Workaround for the weird 2-index movement on cursordown
function preCursorDown(view)
	if view == tree_view then
		tree_view.Cursor:Down()
		select_line()
		-- Don't actually go down, as it moves 2 indicies for some reason
		return false
	end
end

-- Up
function onCursorUp(view)
	selectline_if_tree(view)
end

-- Alt-Shift-{
-- Go to target's parent directory (if exists)
function preParagraphPrevious(view)
	if view == tree_view then
		goto_prev_dir()
		-- Don't actually do the action
		return false
	end
end

-- Alt-Shift-}
-- Go to next dir (if exists)
function preParagraphNext(view)
	if view == tree_view then
		goto_next_dir()
		-- Don't actually do the action
		return false
	end
end

-- PageUp
function onCursorPageUp(view)
	aftermove_if_tree(view)
end

-- Ctrl-Up
function onCursorStart(view)
	aftermove_if_tree(view)
end

-- PageDown
function onCursorPageDown(view)
	selectline_if_tree(view)
end

-- Ctrl-Down
function onCursorEnd(view)
	selectline_if_tree(view)
end

function onNextSplit(view)
	selectline_if_tree(view)
end

function onPreviousSplit(view)
	selectline_if_tree(view)
end

-- On click, open at the click's y
function preMousePress(view, event)
	if view == tree_view then
		local x, y = event:Position()
		-- Fixes the y because softwrap messes with it
		local new_x, new_y = tree_view:GetMouseClickLocation(x, y)
		-- Try to open whatever is at the click's y index
		-- Will go into/back dirs based on what's clicked, nothing gets expanded
		try_open_at_y(new_y)
		-- Don't actually allow the mousepress to trigger, so we avoid highlighting stuff
		return false
	end
end

-- Up
function preCursorUp(view)
	if view == tree_view then
		-- Disallow selecting past the ".." in the tree
		if tree_view.Cursor.Loc.Y == 2 then
			return false
		end
	end
end

-- Left
function preCursorLeft(view)
	if view == tree_view then
		-- +1 because of Go's zero-based index
		-- False to not delete y
		compress_target(get_safe_y(), false)
		-- Don't actually move the cursor, as it messes with selection
		return false
	end
end

-- Right
function preCursorRight(view)
	if view == tree_view then
		-- +1 because of Go's zero-based index
		uncompress_target(get_safe_y())
		-- Don't actually move the cursor, as it messes with selection
		return false
	end
end

-- Workaround for newline getting inserted into opened files
-- Ref https://github.com/zyedidia/micro/issues/992
local enter_pressed = false

-- Enter
function preInsertNewline(view)
	if view == tree_view then
		enter_pressed = true
		-- Open the file
		try_open_at_y(tree_view.Cursor.Loc.Y)
		-- Don't actually insert a newline
		return false
	end
	-- Workaround for newline getting inserted into the opened file
	-- Ref https://github.com/zyedidia/micro/issues/992
	if enter_pressed then
		enter_pressed = false
		return false
	end
	return true
end

-- CtrlL
function onJumpLine(view)
	-- Highlight the line after jumping to it
	-- Also moves you to index 3 (2 in zero-base) if you went to the first 2 lines
	aftermove_if_tree(view)
end

-- ShiftUp
function preSelectUp(view)
	if view == tree_view then
		-- Go to the file/dir's parent dir (if any)
		goto_parent_dir()
		-- Don't actually selectup
		return false
	end
end

-- CtrlF
function preFind(view)
	-- Since something is always selected, clear before a find
	-- Prevents copying the selection into the find input
	clearselection_if_tree(view)
end

-- FIXME: doesn't work for whatever reason
function onFind(view)
	-- Select the whole line after a find, instead of just the input txt
	selectline_if_tree(view)
end

-- CtrlN after CtrlF
function onFindNext(view)
	selectline_if_tree(view)
end

-- CtrlP after CtrlF
function onFindPrevious(view)
	selectline_if_tree(view)
end

-- NOTE: This is a workaround for "cd" not having its own callback
local precmd_dir

function preCommandMode(view)
	precmd_dir = os.Getwd()
end

-- Update the current dir when using "cd"
function onCommandMode(view)
	local new_dir = os.Getwd()
	-- Only do anything if the tree is open, and they didn't cd to nothing
	if tree_view ~= nil and new_dir ~= precmd_dir and new_dir ~= current_dir then
		update_current_dir(new_dir)
	end
end

------------------------------------------------------------------
-- Fail a bunch of useless actions
-- Some of these need to be removed (read-only makes some useless)
------------------------------------------------------------------

function preIndentSelection(view)
	return false_if_tree(view)
end

function preInsertTab(view)
	return false_if_tree(view)
end

function preStartOfLine(view)
	return false_if_tree(view)
end

function preStartOfText(view)
    return false_if_tree(view)
end

function preEndOfLine(view)
	return false_if_tree(view)
end

function preMoveLinesDown(view)
	return false_if_tree(view)
end

function preMoveLinesUp(view)
	return false_if_tree(view)
end

function preWordRight(view)
	return false_if_tree(view)
end

function preWordLeft(view)
	return false_if_tree(view)
end

function preSelectDown(view)
	return false_if_tree(view)
end

function preSelectLeft(view)
	return false_if_tree(view)
end

function preSelectRight(view)
	return false_if_tree(view)
end

function preSelectWordRight(view)
	return false_if_tree(view)
end

function preSelectWordLeft(view)
	return false_if_tree(view)
end

function preSelectToStartOfLine(view)
	return false_if_tree(view)
end

function preSelectToStartOfText(view)
    return false_if_tree(view)
end

function preSelectToEndOfLine(view)
	return false_if_tree(view)
end

function preSelectToStart(view)
	return false_if_tree(view)
end

function preSelectToEnd(view)
	return false_if_tree(view)
end

function preDeleteWordLeft(view)
	return false_if_tree(view)
end

function preDeleteWordRight(view)
	return false_if_tree(view)
end

function preOutdentSelection(view)
	return false_if_tree(view)
end

function preOutdentLine(view)
	return false_if_tree(view)
end

function preSave(view)
	return false_if_tree(view)
end

function preCut(view)
	return false_if_tree(view)
end

function preCutLine(view)
	return false_if_tree(view)
end

function preDuplicateLine(view)
	return false_if_tree(view)
end

function prePaste(view)
	return false_if_tree(view)
end

function prePastePrimary(view)
	return false_if_tree(view)
end

function preMouseMultiCursor(view)
	return false_if_tree(view)
end

function preSpawnMultiCursor(view)
	return false_if_tree(view)
end

function preSelectAll(view)
	return false_if_tree(view)
end

function init()
    -- Let the user disable going to parent directory via left arrow key when file selected (not directory)
    config.RegisterCommonOption("filemanager", "compressparent", true)
    -- Let the user choose to list sub-folders first when listing the contents of a folder
    config.RegisterCommonOption("filemanager", "foldersfirst", true)

    -- Open/close the tree view
    config.MakeCommand("tree", toggle_tree, config.NoComplete)
    -- Create a new path (dirs and files)
    config.MakeCommand("create", new_path, config.NoComplete)
    -- Adds colors to the ".." and any dir's in the tree view via syntax highlighting
    -- TODO: Change it to work with git, based on untracked/changed/added/whatever
    config.AddRuntimeFile("filemanager", config.RTSyntax, "syntax.yaml")
end
