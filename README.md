# dotfiles

A set of configuration files to setup my system. These should work on Linux and MacOS.

![zsh prompt](./resources/prompt.png)

## Installation

### git

- Install [git](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git) (might be pre-installed)
- Copy config files:

```sh
cp git/.gitconfig ~/.gitconfig
```

### zsh

- Install the following:
  - [zsh](https://github.com/robbyrussell/oh-my-zsh/wiki/Installing-ZSH)
  - [nerd-fonts](https://www.nerdfonts.com/)
  - [starship](https://starship.rs/)
  - [zsh-syntax-highlighting](https://github.com/zsh-users/zsh-syntax-highlighting/blob/master/INSTALL.md#oh-my-zsh)
  - [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions/blob/master/INSTALL.md#oh-my-zsh)
  - [fzf](https://github.com/junegunn/fzf)
- Set zsh as your login shell:

```sh
chsh -s $(which zsh)
```

- Copy config files:

```sh
mkdir -p ~/.config
cp zsh/starship/starship.toml ~/.config/starship.toml

mkdir -p ~/.zsh
cp -r zsh/*.zsh ~/.zsh/
cp zsh/.zshrc ~/.zshrc
```

### vim

- Install [vim](https://www.vim.org/) (might be pre-installed)
- Copy config files:

```sh
cp vim/.vimrc ~/.vimrc
```

- When a new file is opened for the first time after updating `~/.vimrc`,
  [vim-plug](https://github.com/junegunn/vim-plug) is installed for managing vim plugins.

## Useful applications

- [ripgrep](https://github.com/BurntSushi/ripgrep): recursively searches directories for a regex
  pattern
- [fd](https://github.com/sharkdp/fd): a simple, fast and user-friendly alternative to 'find'
- [bat](https://github.com/sharkdp/bat): cat(1) clone with wings
- [broot](https://github.com/Canop/broot): a new way to navigate directory trees

### Manjaro linux specific

- [yay](https://github.com/Jguer/yay)
