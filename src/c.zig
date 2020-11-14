pub usingnamespace @cImport({
    @cInclude("locale.h");
    @cDefine("NCURSES_OPAQUE", "0");
    @cDefine("_XOPEN_SOURCE", "700");
    @cDefine("_XOPEN_SOURCE_EXTENDED", "1");
    @cInclude("ncursesw/ncurses.h");
    @cInclude("panel.h");
});
