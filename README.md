```bash
bash <(curl -Ls https://raw.githubusercontent.com/davidbr5264/vless-reality-automated-script/master/setup-xray-reality.sh)
```

As a Digitalocean startup script
```bash
#cloud-config
runcmd:
  - curl -fsSL https://raw.githubusercontent.com/davidbr5264/vless-reality-automated-script/master/setup-xray-reality.sh | bash
````
