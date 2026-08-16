1. Get the file onto the host — download it, or paste it in:

bash
nano ~/show-ip      # paste contents, Ctrl+O, Ctrl+X

2. Make it executable and install it:

bash
chmod +x ~/show-ip
sudo ~/show-ip --install

That copies it to /usr/local/bin/show-ip (mode 755), which is already on root's and every user's PATH.

3. Run it from any directory:

bash
sudo show-ip

Use sudo — without root it can't read listening ports out of container namespaces, and the IPVLAN port column falls back to (need root).

Verify:

bash
command -v show-ip     # -> /usr/local/bin/show-ip
show-ip --version      # -> show-ip 2.0
show-ip --help

If you'd rather not install system-wide, put it in your own bin instead:

bash
mkdir -p ~/.local/bin && cp ~/show-ip ~/.local/bin/ && chmod +x ~/.local/bin/show-ip
grep -q '.local/bin' ~/.bashrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

To update later, overwrite the file and re-run sudo ./show-ip --install. To remove: sudo rm /usr/local/bin/show-ip.