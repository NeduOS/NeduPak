// btw make sure you write comments everywhere i came back to this after 5 days and forgot what everything does
const std = @import("std");
const http = std.http;
const process = std.process;

const Client = http.Client;
const RO = Client.RequestOptions;
const fs = std.fs;

// max body size for http requests it would really suck if this overflowed
const bodySize = 200000;

pub fn main() !void {
    // stdin = input
    // stdout = output
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa_impl.deinit() == .leak) {
        // we have this so if someone is adding something they can know that they messed up
        std.log.err("INTERNEL ERROR: MEMORY LEAK!", .{});
    };
    const gpa = gpa_impl.allocator();

    // http client
    var client = Client{ .allocator = gpa };
    defer client.deinit();
    var headerBuffer: [4096]u8 = undefined;

    // all PR`s that change this line will not be merged
    const printableURL = "https://raw.githubusercontent.com/NeduOS/MainMirror/refs/heads/main/mirror.json";
    const mainURL = try std.Uri.parse(printableURL);

    // command line args
    var args = process.args();

    // iterator
    var i: usize = 1;

    // allocate args list to the heap
    var argsList = std.ArrayList([]const u8).init(std.heap.page_allocator);
    defer argsList.clearAndFree();

    // loop over every arg and append it? what the goofy
    while (args.next()) |arg| : (i += 1)
        // this is gonna get messy
        try argsList.append(arg);

    // put i back to 1 so we can do another loop kinda ziggy
    i = 1;

    while (i < argsList.items.len) : (i += 1)
        // installing
        if (std.mem.eql(u8, argsList.items[i], "-I")) {
            if (i + 1 != argsList.items.len - 1) {
                try stdout.print("FAILED: bad usage try: nedu -I (pkg name here)\n", .{});
            } else {
                const pkgToInstall = argsList.items[i + 1];
                try stdout.print("Checking Local List For: {s}...\n", .{pkgToInstall});
                var buffer: [bodySize]u8 = undefined;

                // all code below here is unholy

                // Linux home
                // btw if you want to know what this is type echo $HOME in your linux terminal
                const home = try std.process.getEnvVarOwned(gpa, "HOME");
                defer gpa.free(home);
                // config dir example: /home/user/.config/nedu
                const configDir = try std.fs.path.join(gpa, &[_][]const u8{ home, ".config/nedu" });
                defer gpa.free(configDir);
                // package list location example: /home/user/.config/nedu/paklist.json
                const pakListLoc = try std.fs.path.join(gpa, &[_][]const u8{ configDir, "/paklist.json" });
                defer gpa.free(pakListLoc);
                // NOT WHERE THE FINAL BINARY IS PLACED THIS IS A CACHE
                const installLoc = try std.fs.path.join(gpa, &[_][]const u8{ configDir, "/cache" });
                defer gpa.free(installLoc);

                // unparsed json from reading pakListLoc
                const jsonUnparsed: []u8 = try std.fs.cwd().readFile(pakListLoc, &buffer);

                // make the json readable
                const parsed = std.json.parseFromSlice(std.json.Value, gpa, jsonUnparsed, .{}) catch |err| {
                    try stdout.print("Failed To Get JSON:\n{s}\n Try Running: nedu -su\n", .{@errorName(err)});
                    return err;
                };
                defer parsed.deinit();

                // check if the package we are installing exists
                if (parsed.value.object.get(pkgToInstall) == null) {
                    try stdout.print("The Package of Name: {s} Does Not Exist in The Json, Want It To Exist? Make A PR Here: https://github.com/NeduOS/MainMirror\n", .{pkgToInstall});
                } else {
                    // get the package data?
                    const pkg = parsed.value.object.get(pkgToInstall).?.array;

                    // get the real data from the package
                    const dataObj = pkg.items[0].object;
                    // get the server
                    const server = dataObj.get("server").?.string;
                    try stdout.print("Contacting Server: {s}\n", .{server});
                    const usableIP = try std.Uri.parse(server);
                    // contact that server
                    var request = try client.open(.GET, usableIP, .{ .server_header_buffer = &headerBuffer });
                    defer request.deinit();

                    // pretend we exist
                    try request.send();
                    try request.finish();
                    try request.wait();

                    if (request.response.status != http.Status.ok) {
                        // they said no :(
                        try stdout.print("Failed Connecting To: {s} Status: {d}\n", .{ server, request.response.status });
                    } else {
                        // they said yes :)

                        // can hold up to 3 letters
                        try stdout.print("Proceed With Install y/n: ", .{});

                        const inputBuffer = try stdin.readUntilDelimiterAlloc(gpa, '\n', 8);
                        defer gpa.free(inputBuffer);

                        const usableInput = std.mem.trim(u8, inputBuffer, "\r");

                        // double checking :D
                        if (inputBuffer.len > 5) {
                            try stdout.print("Please Dont Try To Overflow The Buffer It Is Not Kool Of You\n", .{});
                            std.process.exit(1);
                        }
                        if (std.mem.eql(u8, usableInput, "y")) {
                            try stdout.print("Connected! Starting Transfer\n", .{});

                            // MAKE SURE CACHE IS DELETED AFTER EVERY INSTALL
                            try fs.cwd().makePath(installLoc);

                            // this is a very strange solution
                            // all the urls will end with a file so with can just get the final split
                            var splitURL = std.mem.split(u8, server, "/");
                            var file: ?[]const u8 = undefined;

                            // the logic behind is that if you are connecting to a server
                            // you are requesting the file so the text after the last / should end with a file
                            while (splitURL.next()) |split| {
                                file = split;
                            }

                            // after all that work now we have a path to install at
                            const finalFile = try std.fs.path.join(gpa, &[_][]const u8{ installLoc, file.? });
                            defer gpa.free(finalFile);

                            try stdout.print("putting {s} in cache at: {s}\n", .{ pkgToInstall, finalFile });

                            var bodyBuf: [bodySize]u8 = undefined;
                            const bodyBytes = try request.read(&bodyBuf);

                            try stdout.print("body:\n{s}\n", .{bodyBuf[0..bodyBytes]});

                            const pakage = try fs.cwd().createFile(
                                finalFile,
                                .{ .truncate = true, .read = true },
                            );
                            defer pakage.close();

                            const pak_write = try pakage.writeAll(bodyBuf[0..bodyBytes]);
                            _ = pak_write;

                            try stdout.print("tar saved to disk at: {s}!\n", .{finalFile});
                        }
                    }
                }
            }
        } else {
            // updating or syncing package lock
            if (std.mem.eql(u8, argsList.items[i], "-su")) {
                if (i + 1 == argsList.items.len - 1) {
                    try stdout.print("FAILED: bad usage try: nedu -su\n", .{});
                } else {
                    try stdout.print("Connecting To {s}\n", .{printableURL});
                    var request = try client.open(.GET, mainURL, .{ .server_header_buffer = &headerBuffer });
                    defer request.deinit();

                    try request.send();
                    try request.finish();
                    try request.wait();

                    if (request.response.status != http.Status.ok) {
                        try stdout.print("Failed Connecting To: {s} Status: {d}\n", .{ printableURL, request.response.status });
                    } else {
                        try stdout.print("Connected!\n", .{});
                        var bodyBuf: [bodySize]u8 = undefined;
                        const bodyBytes = try request.readAll(&bodyBuf);

                        const home = try std.process.getEnvVarOwned(gpa, "HOME");
                        defer gpa.free(home);
                        const configDir = try std.fs.path.join(gpa, &[_][]const u8{ home, ".config/nedu" });
                        defer gpa.free(configDir);
                        const pakListLoc = try std.fs.path.join(gpa, &[_][]const u8{ configDir, "/paklist.json" });
                        defer gpa.free(pakListLoc);
                        try fs.cwd().makePath(configDir);

                        try stdout.print("Creating Package list at: {s}\n", .{pakListLoc});

                        const pakList = try fs.cwd().createFile(
                            pakListLoc,
                            .{ .truncate = true, .read = true },
                        );
                        defer pakList.close();

                        const pak_write = try pakList.writeAll(bodyBuf[0..bodyBytes]);
                        _ = pak_write;

                        try stdout.print("file created!\n", .{});
                    }
                }
            }
        };
}
