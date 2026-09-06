#!/usr/libexec/flua

-- SPDX-License-Identifier: BSD-2-Clause
--
-- Copyright(c) 2025 The FreeBSD Foundation.
--
-- This software was developed by Isaac Freund <ifreund@freebsdfoundation.org>
-- under sponsorship from the FreeBSD Foundation.

-- Run a command using the OS shell and capture the stdout
-- Strips exactly one trailing newline if present, does not strip any other whitespace.
-- Asserts that the command exits cleanly
local function capture(command)
	local p = io.popen(command)
	local output = p:read("*a")
	assert(p:close())
	-- Strip exactly one trailing newline from the output, if there is one
	return output:match("(.-)\n$") or output
end

-- Returns the first argument that was actually given.  A make variable that
-- expands to nothing arrives here as an empty string rather than as no
-- argument at all, and an empty prefix selects nothing at all -- every name
-- would have to begin with "-set-" -- so it must fall through to the default
-- instead of being taken as a deliberate choice.
local function given(value, fallback)
	if value == nil or value == "" then
		return fallback
	end
	return value
end

-- Returns a list of packages to be included in the given media
local function select_packages(pkg, media, all_libcompats, prefix)
	-- Note: if you update this list, or how the prefix is escaped before
	-- being matched on, you must make the same change in
	-- usr.sbin/bsdinstall/scripts/pkgbase.in, which selects the same
	-- packages again at install time and takes the same prefix.  Both
	-- fail by selecting nothing rather than by erroring, so a change made
	-- in only one of them is quiet.
	local kernel_packages = {
		-- Most architectures use this
		[prefix .. "-kernel-generic"] = true,
		-- PowerPC uses either of these, depending on platform
		[prefix .. "-kernel-generic64"] = true,
		[prefix .. "-kernel-generic64le"] = true,
	}

	local components = {}
	-- The repository name is an alias local to this build, written by the
	-- pkgbase-repo-dir target in release/Makefile, and is deliberately not
	-- derived from the prefix: renaming the packages does not rename the
	-- repository they are fetched from.
	local rquery = capture(pkg .. "rquery -U -r FreeBSD-base %n")
	-- The prefix is a literal here, not a pattern, so escape the characters
	-- Lua patterns treat specially before matching on it.
	local prefix_pat = prefix:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
	for package in rquery:gmatch("[^\n]+") do
		local set = package:match("^" .. prefix_pat .. "%-set%-(.*)$")
		if set then
			components[set] = package
		elseif kernel_packages[package] then
			components["kernel"] = package
		elseif kernel_packages[package:match("(.*)%-dbg$")] then
			components["kernel-dbg"] = package
		elseif package == "pkg" then
			components["pkg"] = package
		end
	end
	assert(components["kernel"], "no " .. prefix .. "-kernel-generic* package")
	assert(components["base"], "no " .. prefix .. "-set-base package")
	assert(components["pkg"],
	    "no pkg package (the pkgbase-repo target builds it from ports)")

	local selected = {}
	if media == "disc" then
		table.insert(selected, components["pkg"])
		table.insert(selected, components["base"])
		table.insert(selected, components["base-jail"])
		table.insert(selected, components["kernel"])
		table.insert(selected, components["kernel-dbg"])
		table.insert(selected, components["src"])
		table.insert(selected, components["tests"])
		for compat in all_libcompats:gmatch("%S+") do
			table.insert(selected, components["lib" .. compat])
		end
	else
		assert(media == "dvd")
		table.insert(selected, components["pkg"])
		table.insert(selected, components["base"])
		table.insert(selected, components["base-dbg"])
		table.insert(selected, components["base-jail"])
		table.insert(selected, components["base-jail-dbg"])
		table.insert(selected, components["kernel"])
		table.insert(selected, components["kernel-dbg"])
		table.insert(selected, components["src"])
		table.insert(selected, components["tests"])
		for compat in all_libcompats:gmatch("%S+") do
			table.insert(selected, components["lib" .. compat])
			table.insert(selected, components["lib" .. compat .. "-dbg"])
		end
	end

	return selected
end

local function main()
	-- Determines package subset selected
	local media = assert(arg[1])
	assert(media == "disc" or media == "dvd")
	-- Directory containing FreeBSD-base repository config
	local repo_dir = assert(arg[2])
	-- Directory to create new repository
	local target = assert(arg[3])
	-- Whitespace separated list of all libcompat names (e.g. "32")
	local all_libcompats = assert(arg[4])
	-- ABI of repository
	local ABI = assert(arg[5])
	-- pkgdb to use
	local PKGDB = assert(arg[6])
	-- Prefix the base packages are named with. A build that renames its
	-- packages -- PKG_NAME_PREFIX in bsd.pkg.pre.mk -- still has to be able
	-- to stage them onto media, and this script previously matched
	-- "FreeBSD-" literally, so it selected nothing and failed an assertion
	-- with no indication that the name was the problem. Optional, and
	-- defaulting to the same value bsd.pkg.pre.mk does, so the behaviour is
	-- unchanged for a stock build.
	local prefix = given(arg[7], given(os.getenv("PKG_NAME_PREFIX"), "FreeBSD"))

	local pkg = "pkg -o ASSUME_ALWAYS_YES=yes -o IGNORE_OSVERSION=yes " ..
	    "-o ABI=" .. ABI .. " " ..
	    "-o INSTALL_AS_USER=1 -o PKG_DBDIR=" .. PKGDB .. " -R " .. repo_dir .. " "

	assert(os.execute(pkg .. "update"))

	local packages = select_packages(pkg, media, all_libcompats, prefix)

	assert(os.execute(pkg .. "fetch -d -o " .. target .. " " .. table.concat(packages, " ")))
	assert(os.execute(pkg .. "repo " .. target))
end

main()
