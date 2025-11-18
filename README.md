# deb-downloader

Download .deb packages directly from APT repositories without adding them to sources.list.

## Usage

Interactive mode:
```bash
./deb-downloader
```

Non-interactive:
```bash
./deb-downloader --url "deb https://example.com/debian stable main" --package mypackage
```

Run directly via curl:
```bash
curl -fsSL <SCRIPT_URL> | bash -s -- --url "https://example.com/debian" --package mypackage --dist stable
```

## Requirements

Uses uv for dependency management (auto-installs on first run).

## Install

```bash
sudo dpkg -i <package>.deb
sudo apt-get install -f  # if dependencies are missing
```
