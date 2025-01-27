local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node
local i = ls.insert_node

ls.add_snippets("zig", {
  s("icast", {
    t("@as("),
    i(1, "type"),
    t(", @intCast("),
    i(2, "value"),
    t("));"),
  }),
})
