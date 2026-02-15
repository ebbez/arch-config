#
# ~/.bashrc
#
export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent.socket"

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias vim='nvim'
alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '
