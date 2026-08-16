# 🌐 show-ip

Simple Linux utility for displaying IP, interface, container, and listening-port information.

## 📦 Installation

### 📜 Script

```bash
nano ~/show-ip
```

Paste the script, then save and exit.

### ⚙️ Install

```bash
chmod +x ~/show-ip
sudo ~/show-ip --install
```

Installs to:

```text
/usr/local/bin/show-ip
```

## 🚀 Usage

```bash
sudo show-ip
```

> [!IMPORTANT]
> Run with `sudo` for full container namespace and IPVLAN port information.

## 🔍 Verify

```bash
command -v show-ip
show-ip --version
show-ip --help
```

Expected:

```text
/usr/local/bin/show-ip
show-ip 2.0
```

## 🔄 Update

Replace the script and run:

```bash
sudo ~/show-ip --install
```

## 🗑️ Uninstall

```bash
sudo rm /usr/local/bin/show-ip
```

## 🏠 User-local Install

If you don't want a system-wide installation:

```bash
mkdir -p ~/.local/bin
cp ~/show-ip ~/.local/bin/
chmod +x ~/.local/bin/show-ip
```

Add it to your `PATH` if needed:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```
