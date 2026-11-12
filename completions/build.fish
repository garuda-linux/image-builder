# The words after the options: the output, then its arguments
function __garuda_build_positional
    set -l skip 0
    for token in (commandline -opc)[2..]
        if test $skip -eq 1
            set skip 0
            continue
        end
        switch $token
            case --rebuild-layer
                set skip 1
            case '--*'
            case '*'
                echo $token
        end
    end
end

# __garuda_build_at <output> <n>: the next word is argument n of that output
function __garuda_build_at
    set -l words (__garuda_build_positional)
    test (count $words) -eq $argv[2]; and test "$words[1]" = $argv[1]
end

function __garuda_build_no_output
    test (count (__garuda_build_positional)) -eq 0
end

function __garuda_build_editions
    set -l root (git rev-parse --show-toplevel 2>/dev/null); or return
    for dir in $root/mkosi.images/desktop/mkosi.profiles/*/
        basename $dir
    end
end

# build pkg <verb>: only the devshell wrapper has it, as its first argument
function __garuda_build_pkg_verbless
    set -l words (commandline -opc)
    test (count $words) -eq 2; and test "$words[2]" = pkg
end

function __garuda_build_pkg_verb
    set -l words (commandline -opc)
    test "$words[2]" = pkg; and test (count $words) -ge 3; and test "$words[3]" = $argv[1]
end

function __garuda_build_pkgbases
    set -l root (git rev-parse --show-toplevel 2>/dev/null); or return
    set -l pkgbuilds $root/../pkgbuilds
    set -q GARUDA_PKGBUILDS; and set pkgbuilds $GARUDA_PKGBUILDS
    set -l words (commandline -opc)
    for i in (seq (count $words))
        test "$words[$i]" = --pkgbuilds; and set -q words[(math $i + 1)]; and set pkgbuilds $words[(math $i + 1)]
    end
    for file in $pkgbuilds/*/PKGBUILD
        basename (dirname $file)
    end
end

function __garuda_build_local_packages
    set -l root (git rev-parse --show-toplevel 2>/dev/null); or return
    for file in $root/mkosi.packages/*.pkg.tar*
        string match -q '*.sig' -- $file; and continue
        string replace -r -- '-[^-]+-[^-]+-[^-]+\.pkg\.tar.*$' '' (basename $file)
    end
end

complete -c build -n 'test (count (commandline -opc)) -eq 1' -a pkg -d 'local packages with cpb'
complete -c build -n __garuda_build_pkg_verbless -a build -d 'build packages into mkosi.packages/'
complete -c build -n __garuda_build_pkg_verbless -a list -d 'list local packages'
complete -c build -n __garuda_build_pkg_verbless -a rm -d 'remove local packages'
complete -c build -n __garuda_build_pkg_verbless -a clean -d 'remove all local packages'
complete -c build -n '__garuda_build_pkg_verb build' -a '(__garuda_build_pkgbases)' -d pkgbase
complete -c build -n '__garuda_build_pkg_verb build' -l pkgbuilds -x -a '(__fish_complete_directories)' -d 'pkgbuilds repository'
complete -c build -n '__garuda_build_pkg_verb build' -l src -x -a '(__fish_complete_directories)' -d 'local source checkout'
complete -c build -n '__garuda_build_pkg_verb build' -l dir -x -d 'extracted source directory'
complete -c build -n '__garuda_build_pkg_verb rm' -a '(__garuda_build_local_packages)' -d 'local package'

for cmd in build build.sh
    complete -c $cmd -f
    complete -c $cmd -n __garuda_build_no_output -a 'distrobox lima iso vm uki' -d output
    complete -c $cmd -n __garuda_build_no_output -a clean -d 'remove old images, layers, caches'
    complete -c $cmd -n __garuda_build_no_output -l refresh-keys -d 'download the chaotic keyring again'
    complete -c $cmd -n __garuda_build_no_output -l fresh -d 'rebuild every layer'
    complete -c $cmd -n __garuda_build_no_output -l rebuild-layer -x -a 'base root desktop live mhwd live-initrd' -d 'rebuild a layer'
    complete -c $cmd -n __garuda_build_no_output -l explain -d 'show which layers would be rebuilt'
    complete -c $cmd -n __garuda_build_no_output -l container -d 'build in the builder image'
    complete -c $cmd -n __garuda_build_no_output -l rebuild-builder -d 'build the builder image again'
    complete -c $cmd -n '__garuda_build_at iso 1; or __garuda_build_at vm 1' -a '(__garuda_build_editions)' -d edition
    complete -c $cmd -n '__garuda_build_at clean 1' -a 'old layers caches all' -d level
    complete -c $cmd -n '__garuda_build_at clean 2' -l yes -d 'do not ask'
end
