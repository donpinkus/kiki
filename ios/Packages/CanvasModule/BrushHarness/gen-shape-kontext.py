import base64, io, json, os, time, urllib.request, urllib.error, glob
from PIL import Image, ImageOps
FAL_KEY = os.environ["FAL_KEY"]
SLUG = "fal-ai/flux-kontext/dev"
PROMPT = ("Recreate this exact brush-tip texture with subtle natural variation. Keep the same "
          "silhouette, the same grainy speckled interior, and the black-shape-on-white-background "
          "look. Do not add paper, borders, shadows, or any scene.")
INIT_DIR = "/tmp/img2img/libinit"
OUT = "/tmp/kontext-lib"; os.makedirs(f"{OUT}/mask", exist_ok=True)
def gen(path):
    name = os.path.basename(path)[:-4]
    if os.path.exists(f"{OUT}/mask/{name}.png"): print(f"SKIP {name}", flush=True); return
    t0=time.time()
    init = ImageOps.invert(Image.open(path).convert("L"))  # black-on-white for the model
    buf = io.BytesIO(); init.convert("RGB").save(buf,"PNG")
    uri = "data:image/png;base64,"+base64.b64encode(buf.getvalue()).decode()
    body = {"prompt":PROMPT,"image_url":uri,"guidance_scale":2.5,"num_inference_steps":28,"num_images":1}
    for attempt in range(3):
        r = urllib.request.Request(f"https://fal.run/{SLUG}", data=json.dumps(body).encode(),
            method="POST", headers={"Authorization":f"Key {FAL_KEY}","Content-Type":"application/json"})
        try:
            res = json.load(urllib.request.urlopen(r, timeout=180)); break
        except urllib.error.HTTPError as e:
            if attempt==2: print(f"FAIL {name}: {e.code}", flush=True); return
            time.sleep(3)
    raw = urllib.request.urlopen(res["images"][0]["url"], timeout=120).read()
    out = Image.open(io.BytesIO(raw)).convert("L")
    ImageOps.autocontrast(ImageOps.invert(out)).save(f"{OUT}/mask/{name}.png")  # white-on-black mask
    print(f"OK {name} {time.time()-t0:.0f}s", flush=True)
for p in sorted(glob.glob(f"{INIT_DIR}/*.png")):
    gen(p)
print("ALLDONE", flush=True)
