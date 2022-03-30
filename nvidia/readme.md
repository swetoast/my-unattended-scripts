## NVIDIA Graphics Card Fan Controller

How to set up headless mode for Nvidia Settings

1. Download fresh drivers, https://www.nvidia.com/Download/index.aspx?lang=en-us
2. Install a minimal x11 enviorment
3. Edit grub to use console mode only `/etc/default/grub`
4. Download and enable fancontrol.service and install `fancontrol` to `/usr/bin`

```bash
sudo apt-get install --no-install-recommends xorg lightdm -y
sudo systemctl disable lightdm.service
sudo systemctl enable multi-user.target --force
sudo systemctl set-default multi-user.target
```
