-- lua/mason-local/init.lua
--
-- A mason registry of our own, for packages whose upstream entry does not
-- install. Registered ahead of mason-org's in lua/plugins/sqls.lua, so a name
-- defined here shadows the upstream package of the same name.
--
-- Maps package name to the module holding its spec, in the same schema as
-- mason-org/mason-registry's registry.json.
return {
  sqls = "mason-local.sqls",
}
