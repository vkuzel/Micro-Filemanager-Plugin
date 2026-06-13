# Micro Filemanager Plugin

A stripped down version of [Nicolai Soeborg's](https://github.com/NicolaiSoeborg) [Filemanager Plugin](https://github.com/micro-editor/updated-plugins/tree/master/filemanager-plugin) for the [Micro editor](https://github.com/micro-editor/MICRO).

### Commands

- `tree` - open the plugin
- `create` - create and open a file path - accepts a full path, creates parent directories if the doesn't exist.

### Bindings
- <kbd>Enter</kbd> & MouseLeft - Open a file, or go into the directory. Goes back a dir if on `..` - `filemanager.try_open_at_cursor`
- <kbd>→</kbd> - Expand directory in tree listing - `filemanager.uncompress_at_cursor`
- <kbd>←</kbd> - Collapse directory listing - `filemanager.compress_at_cursor`
- <kbd>Shift ⬆</kbd> - Go to the target's parent directory - `filemanager.goto_parent_dir`
- <kbd>Alt Shift {</kbd> - Jump to the previous directory in the view - `filemanager.goto_next_dir`
- <kbd>Alt Shift }</kbd> - Jump to the next directory in the view - `filemanager.goto_prev_dir`
