```bash
bash <(curl -Ls https://raw.githubusercontent.com/davidbr5264/vless-reality-automated-script/master/setup-xray-reality.sh)
```
```bash
#cloud-config
runcmd:
  - curl -sSL curl -Ls https://raw.githubusercontent.com/davidbr5264/vless-reality-automated-script/master/setup-xray-reality.sh | bash

````
