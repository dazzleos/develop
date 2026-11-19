# Develop

Write programs in Zig and run them on this computer: an editor beside the
output, with the Zig compiler built in. An app for
[Dazzle](https://github.com/dazzleos/dazzle).

Install it on Dazzle from Settings, Software.

## Building

Develop is built with Dazzle's modules (kete_vc4 and the rest) and tools,
through Dazzle's `addApp` (see its `build.zig`): a commit of Dazzle's, as
`build.zig.zon` pins it. Zig is the version Dazzle's `scripts/zig` fetches:

    git clone https://github.com/dazzleos/dazzle ../dazzle
    ../dazzle/scripts/zig build test    # the tests, on this computer
    ../dazzle/scripts/zig build         # the program, and zig-out/apps

The compiler it bundles (Zig for ARM Linux, as `build.zig` pins it) is
downloaded from ziglang.org into `build/zig` the first time, and checked.

With changes of your own to Dazzle, build with that checkout instead:
`--fork=../dazzle`. To move Develop on to a newer Dazzle, pin its commit:

    git -C ../dazzle archive --format=tar.gz -o /tmp/dazzle.tar.gz <commit>
    zig fetch /tmp/dazzle.tar.gz        # prints the hash for build.zig.zon

(the archive has only the commit's files, so this is quick, and its hash
is the one fetching the commit from GitHub gives).

`zig-out/apps` has Develop's archive, icon, screenshot and catalogue
(`apps.json`), signed with `-Dsigning-key` or `DAZZLE_SIGNING_KEY`. Each
push to the default branch publishes them as the "latest" release, one of
the sources Dazzle's catalogue lists.

To try a build on a Pi before publishing it, serve it with Dazzle's
(Settings, Software, Software server):

    cd ../dazzle && zig build serve -- --source=develop=../develop/zig-out
