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
