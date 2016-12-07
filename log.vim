if exists("b:current_syntax")
    finish
endif

" Highlight the times
syntax match unboundTime "\v\[\d{2}\/\w{3}\/\d{4}(\:\d{2}){3}(.\d{3})?(\s\-|\+)+\d{4}\]"
highlight link unboundTime Type

" Highlights text before the equals sign
syntax match unboundDetails "\v\s[a-zA-Z]+\="
"syntax match unboundDetails "\v\/[a-zA-Z-_]{2,20}\s"
highlight link unboundDetails Comment

" Highlights the text between brackets
syntax region unboundInfo start=/\v\(/ end=/\v\)/
syntax region unboundInfo start=/\v\{/ end=/\v\}/
syntax region unboundInfo start=/\v\'/ end=/\v\'/
highlight link unboundInfo Statement

syntax region unboundInfo start=/\v\'/ end=/\v\'/
highlight link unboundInfo Function

" Highlights error text
syntax keyword unboundSpecial SEVERE_ERROR
syntax match unboundSpecial "\v\*+"
highlight link unboundSpecial Error

let b:current_syntax = "unbound"
