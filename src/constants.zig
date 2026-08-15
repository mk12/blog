// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module defines some constants used by the rest of the program.

const std = @import("std");
const Date = @import("Date.zig");

pub const site_url = "https://mitchellkember.com";

pub const src_dir = "samples";
pub const src_site_dir = "samples/public";
pub const src_template_dir = "samples/_templates";

pub const src_site_depth = std.mem.count(u8, src_site_dir, "/") + 1;

pub const out_dir = "out";

pub const max_file_size: std.Io.Limit = .limited(1024 * 1024);

pub const num_doc_types = 4;

pub const rss_cutoff = Date.from("2024-01-01T00:00:00+00:00");
