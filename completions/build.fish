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

# __garuda_build_items <item>...: the next item of --test=a,b or --virt=a,b
function __garuda_build_items
    set -l done (commandline -ct | string replace -r '^--[a-z]+=' '' | string replace -r '[^,]*$' '')
    for item in $argv
        echo $done$item
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

# build test|virt <output> ...: only the devshell wrapper has them, as its first argument
# __garuda_build_verb_at <verb> <output> <n>: the next word is argument n after "<verb> <output>"
function __garuda_build_verb_at
    set -l words (commandline -opc)
    test "$words[2]" = $argv[1]; or return 1
    test (count $words) -ge 3; and test "$words[3]" = $argv[2]; or return 1
    test $argv[3] = any; and return 0
    test (count $words) -eq (math $argv[3] + 2)
end

function __garuda_build_test_at
    __garuda_build_verb_at test $argv
end

function __garuda_build_virt_at
    __garuda_build_verb_at virt $argv
end

# __garuda_build_verbless <verb>: the next word is the output after <verb>
function __garuda_build_verbless
    set -l words (commandline -opc)
    test (count $words) -eq 2; and test "$words[2]" = $argv[1]
end

complete -c build -n 'test (count (commandline -opc)) -eq 1' -a test -d 'test a built image'
complete -c build -n '__garuda_build_verbless test' -a 'iso vm lima distrobox oci' -d output
complete -c build -n '__garuda_build_test_at iso 1; or __garuda_build_test_at vm 1' -a '(__garuda_build_editions)' -d edition
complete -c build -n '__garuda_build_test_at iso any' -l openqa -d 'openQA install run instead of iso-test'
complete -c build -n '__garuda_build_test_at iso any' -l cdrom -d 'ISO as CD drive'
complete -c build -n '__garuda_build_test_at iso any' -l disk -d 'add an install disk'
complete -c build -n '__garuda_build_test_at iso any' -l boot-disk -d 'boot the install disk'
complete -c build -n '__garuda_build_test_at iso any' -l secure-boot -d 'Secure Boot on'
complete -c build -n '__garuda_build_test_at iso any; or __garuda_build_test_at vm any' -l ram -x -d 'RAM of the VM'
complete -c build -n '__garuda_build_test_at iso any; or __garuda_build_test_at vm any; or __garuda_build_test_at lima any' -l keep -d 'keep the VM state'
complete -c build -n '__garuda_build_test_at iso any; or __garuda_build_test_at vm any' -l serial -d 'console in the terminal'
complete -c build -n '__garuda_build_test_at iso any; or __garuda_build_test_at vm any' -l version -x -d 'an older image, YYYYMMDD'
complete -c build -n '__garuda_build_test_at vm any' -l ssh -d 'root ssh over vsock'
complete -c build -n '__garuda_build_no_output; and not __fish_seen_subcommand_from test pkg virt ls journal shell which diff flash verify' -l notify -d 'desktop notification at the end'
complete -c build -n '__garuda_build_no_output; and not __fish_seen_subcommand_from test pkg virt ls journal shell which diff flash verify' -l test -f -a '(__garuda_build_items cdrom disk boot-disk secure-boot keep serial ssh ram= version=)' -d 'test the image after the build'
complete -c build -n '__garuda_build_no_output; and not __fish_seen_subcommand_from test pkg virt ls journal shell which diff flash verify' -l openqa -d 'openQA run after the ISO build'
complete -c build -n '__garuda_build_no_output; and not __fish_seen_subcommand_from test pkg virt ls journal shell which diff flash verify' -l tag -f -d 'import oci or distrobox into podman and docker'
complete -c build -n '__garuda_build_no_output; and not __fish_seen_subcommand_from test pkg virt ls journal shell which diff flash verify' -l virt -f -a '(__garuda_build_items new new= open attach disk secure-boot ram= version=)' -d 'libvirt domain after the build'

complete -c build -n 'test (count (commandline -opc)) -eq 1' -a virt -d 'libvirt domain from an image'
complete -c build -n '__garuda_build_verbless virt' -a 'iso vm' -d output
complete -c build -n '__garuda_build_verbless virt' -a list -d 'list the garuda-* domains'
complete -c build -n '__garuda_build_verbless virt' -a rm -d 'remove domains with storage and journal'
complete -c build -n '__garuda_build_verb_at virt rm any' -a '(virsh --connect qemu:///system --quiet list --all --name 2>/dev/null | string match "garuda-*")' -d domain
complete -c build -n '__garuda_build_verb_at virt rm any' -l all -d 'every garuda-* domain'
complete -c build -n '__garuda_build_virt_at iso 1; or __garuda_build_virt_at vm 1' -a '(__garuda_build_editions)' -d edition
complete -c build -n '__garuda_build_virt_at iso any; or __garuda_build_virt_at vm any' -l new -d 'another domain, optional =<name>'
complete -c build -n '__garuda_build_virt_at iso any; or __garuda_build_virt_at vm any' -l open -d 'open the console in virt-manager'
complete -c build -n '__garuda_build_virt_at iso any; or __garuda_build_virt_at vm any' -l attach -d 'follow the journal, Ctrl+C shuts down'
complete -c build -n '__garuda_build_virt_at iso any' -l disk -d 'add an install disk'
complete -c build -n '__garuda_build_virt_at iso any' -l secure-boot -d 'Secure Boot on, MokManager enrolls the cert'
complete -c build -n '__garuda_build_virt_at iso any; or __garuda_build_virt_at vm any' -l ram -x -d 'RAM of the VM'
complete -c build -n '__garuda_build_virt_at iso any; or __garuda_build_virt_at vm any' -l version -x -d 'an older image, YYYYMMDD'

complete -c build -n 'test (count (commandline -opc)) -eq 1' -a ls -d 'the current images'
complete -c build -n 'test (count (commandline -opc)) -eq 1' -a journal -d 'guest journal of the last test VM'
complete -c build -n '__garuda_build_verbless journal' -a 'iso vm virt' -d 'VM kind'
complete -c build -n '__garuda_build_verb_at journal virt 1' -a '(path basename (path filter -d ~/.local/state/garuda-libvirt/*))' -d domain
complete -c build -n 'test (count (commandline -opc)) -eq 1' -a shell -d 'ephemeral shell in a layer tree'
complete -c build -n '__garuda_build_verbless shell' -a 'base root desktop' -d layer
complete -c build -n 'test (count (commandline -opc)) -eq 1' -a which -d 'where a package comes from'
complete -c build -n 'test (count (commandline -opc)) -eq 1' -a diff -d 'package changes between two ISO versions'
complete -c build -n 'test (count (commandline -opc)) -eq 1' -a flash -d 'write an ISO to a USB stick'
complete -c build -n 'test (count (commandline -opc)) -eq 1' -a verify -d 'checksum and Secure Boot signatures of an ISO'
complete -c build -n '__garuda_build_verbless diff; or __garuda_build_verbless flash; or __garuda_build_verbless verify' -a '(__garuda_build_editions)' -d edition
complete -c build -n '__fish_seen_subcommand_from flash; and test (count (commandline -opc)) -ge 3' -a '(lsblk -dnpo NAME,TYPE 2>/dev/null | string match -r "^\S+(?= +disk)" | string match -v "*zram*")' -d disk
complete -c build -n '__fish_seen_subcommand_from flash; and test (count (commandline -opc)) -ge 3' -l yes -d 'do not ask'
complete -c build -n '__fish_seen_subcommand_from flash verify; and test (count (commandline -opc)) -ge 3' -l version -x -d 'an older ISO, YYYYMMDD'

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
    complete -c $cmd -n __garuda_build_no_output -a 'distrobox oci lima iso vm uki' -d output
    complete -c $cmd -n __garuda_build_no_output -a clean -d 'remove old images, layers, caches'
    complete -c $cmd -n __garuda_build_no_output -l refresh-keys -d 'download the chaotic keyring again'
    complete -c $cmd -n __garuda_build_no_output -l fresh -d 'rebuild every layer'
    complete -c $cmd -n __garuda_build_no_output -l rebuild-layer -x -a 'base root desktop live drivers live-initrd' -d 'rebuild a layer'
    complete -c $cmd -n __garuda_build_no_output -l explain -d 'show which layers would be rebuilt'
    complete -c $cmd -n __garuda_build_no_output -l container -d 'build in the builder image'
    complete -c $cmd -n __garuda_build_no_output -l rebuild-builder -d 'build the builder image again'
    complete -c $cmd -n '__garuda_build_at iso 1; or __garuda_build_at vm 1' -a '(__garuda_build_editions)' -d edition
    complete -c $cmd -n '__garuda_build_at clean 1' -a 'old layers caches all' -d level
    complete -c $cmd -n '__garuda_build_at clean 2' -l yes -d 'do not ask'
end
