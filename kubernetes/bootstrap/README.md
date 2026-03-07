# bootstrap

## Bootstrap SOPS age key

```bash
cat sops/key.txt| kubectl create secret generic sops-age --namespace flux-system --from-file=key=/dev/stdin
```
