import Foundation

// Replicates the SHIPPED renderer tables (setupWetKMTables) + the wetStampFragment KM math,
// to confirm the Metal port reproduces the validated km_tune_final spike at deposit w=0.5.

let NB = 36
let wl: [Double] = (0..<NB).map { 400.0 + Double($0) * (300.0 / Double(NB - 1)) }
func g(_ x:Double,_ mu:Double,_ s1:Double,_ s2:Double)->Double{ let t=(x-mu)*(x<mu ? 1/s1:1/s2); return exp(-0.5*t*t) }
func xbar(_ l:Double)->Double{ 1.056*g(l,599.8,37.9,31.0)+0.362*g(l,442.0,16.0,26.7)-0.065*g(l,501.1,20.4,26.2) }
func ybar(_ l:Double)->Double{ 0.821*g(l,568.8,46.9,40.5)+0.286*g(l,530.9,16.3,31.1) }
func zbar(_ l:Double)->Double{ 1.217*g(l,437.0,11.8,36.0)+0.681*g(l,459.0,26.0,13.8) }
func d65(_ l:Double)->Double{ 100.0*exp(-0.5*pow((l-470)/260,2)) + 12.0*exp(-0.5*pow((l-600)/90,2)) }
let ill = wl.map(d65), xb = wl.map(xbar), yb = wl.map(ybar), zb = wl.map(zbar)
var knorm = 0.0; for i in 0..<NB { knorm += ill[i]*yb[i] }
var mat = [(Double,Double,Double)](repeating:(0,0,0), count: NB)
for i in 0..<NB { let e=ill[i]/knorm; let X=e*xb[i],Y=e*yb[i],Z=e*zb[i]
    mat[i]=(3.2406*X-1.5372*Y-0.4986*Z, -0.9689*X+1.8758*Y+0.0415*Z, 0.0557*X-0.2040*Y+1.0570*Z) }
func clampS(_ v:Double)->Double{ max(0.004,min(1.0,v)) }
func sig(_ x:Double)->Double{ 1/(1+exp(-x)) }
func bmp(_ l:Double,_ mu:Double,_ w:Double)->Double{ exp(-0.5*pow((l-mu)/w,2)) }
let aS=0.32, wS=26.0, aR=0.32
func basis(_ k:Int,_ l:Double)->Double{ switch k {
    case 0: return clampS(0.985); case 1: return clampS(0.02+0.96*sig((555-l)/20))
    case 2: return clampS(0.02+0.96*(sig((465-l)/18)+sig((l-595)/18))); case 3: return clampS(0.02+0.96*sig((l-520)/16))
    case 4: return clampS(0.02+0.96*sig((l-595)/10)); case 5: return clampS(0.02+0.96*bmp(l,540,42))
    default: return clampS(0.02+0.96*(bmp(l,458,32)+aS*bmp(l,520,wS)+aR*bmp(l,660,30))*sig((l-415)/12)) } }
var basisD=[[Double]](); for k in 0..<7 { basisD.append(wl.map{ basis(k,$0) }) }

func sToL(_ c:Double)->Double{ c<=0.04045 ? c/12.92 : pow((c+0.055)/1.055,2.4) }
func lToS(_ c:Double)->Double{ let x=max(0,min(1,c)); return x<=0.0031308 ? x*12.92 : 1.055*pow(x,1/2.4)-0.055 }
func upsample(_ lin:(Double,Double,Double))->[Double]{
    let r=max(0,lin.0),gc=max(0,lin.1),b=max(0,lin.2); var w=[Double](repeating:0,count:7)
    let mn=min(r,min(gc,b)); w[0]=mn; let rr=r-mn,gg=gc-mn,bb=b-mn
    if rr<=gg&&rr<=bb { w[1]=min(gg,bb); if gg>bb {w[5]=gg-bb} else {w[6]=bb-gg} }
    else if gg<=rr&&gg<=bb { w[2]=min(rr,bb); if rr>bb {w[4]=rr-bb} else {w[6]=bb-rr} }
    else { w[3]=min(rr,gg); if rr>gg {w[4]=rr-gg} else {w[5]=gg-rr} }
    var spec=[Double](repeating:0,count:NB)
    for k in 0..<7 where w[k]>0 { for i in 0..<NB { spec[i]+=w[k]*basisD[k][i] } }
    for i in 0..<NB { spec[i]=clampS(spec[i]) }; return spec }
func ksD(_ R:Double)->Double{ let r=max(1e-4,min(1.0-1e-6,R)); return (1-r)*(1-r)/(2*r) }
func specToLin(_ s:[Double])->(Double,Double,Double){ var a=(0.0,0.0,0.0); for i in 0..<NB { a.0+=s[i]*mat[i].0; a.1+=s[i]*mat[i].1; a.2+=s[i]*mat[i].2 }; return a }

// Replicate wetStampFragment for dst (canvas) mixed toward brush by weight w.
func shaderMix(dstSRGB:[Double], brushSRGB:[Double], w:Double)->[Int]{
    let dstLin=(sToL(dstSRGB[0]),sToL(dstSRGB[1]),sToL(dstSRGB[2]))
    let brushLin=(sToL(brushSRGB[0]),sToL(brushSRGB[1]),sToL(brushSRGB[2]))
    let specBrush=upsample(brushLin); let brushKS=specBrush.map(ksD)
    let brushRT=specToLin(specBrush)
    let brushResidual=(brushLin.0-brushRT.0, brushLin.1-brushRT.1, brushLin.2-brushRT.2)
    let specDst=upsample(dstLin)
    var mixLin=(0.0,0.0,0.0), dstRT=(0.0,0.0,0.0)
    for i in 0..<NB { let A=mat[i]; dstRT.0+=specDst[i]*A.0; dstRT.1+=specDst[i]*A.1; dstRT.2+=specDst[i]*A.2
        let ksm=ksD(specDst[i])*(1-w)+brushKS[i]*w; let Rm=max(0,min(1,1+ksm-sqrt(ksm*ksm+2*ksm)))
        mixLin.0+=Rm*A.0; mixLin.1+=Rm*A.1; mixLin.2+=Rm*A.2 }
    func cl(_ v:Double)->Double{ max(0,min(1,v)) }
    mixLin=(cl(mixLin.0),cl(mixLin.1),cl(mixLin.2)); dstRT=(cl(dstRT.0),cl(dstRT.1),cl(dstRT.2))
    let bRTc=(cl(brushRT.0),cl(brushRT.1),cl(brushRT.2))
    let brushResidualC=(brushLin.0-bRTc.0, brushLin.1-bRTc.1, brushLin.2-bRTc.2); _ = brushResidual
    let c0=mixLin.0+(1-w)*(dstLin.0-dstRT.0)+w*brushResidualC.0
    let c1=mixLin.1+(1-w)*(dstLin.1-dstRT.1)+w*brushResidualC.1
    let c2=mixLin.2+(1-w)*(dstLin.2-dstRT.2)+w*brushResidualC.2
    return [Int((lToS(c0)*255).rounded()),Int((lToS(c1)*255).rounded()),Int((lToS(c2)*255).rounded())]
}

let blue=[0.10,0.20,0.80], yellow=[0.98,0.86,0.10], red=[0.88,0.10,0.10], green=[0.10,0.65,0.20], magenta=[0.90,0.05,0.55]
print("Shader KM at w=0.5 (dst mixed toward brush) — should match spike 50/50:")
print("  blue over yellow → \(shaderMix(dstSRGB:yellow,brushSRGB:blue,w:0.5))   (spike blue+yellow=(78,137,104))")
print("  yellow over blue → \(shaderMix(dstSRGB:blue,brushSRGB:yellow,w:0.5))")
print("  red over blue    → \(shaderMix(dstSRGB:blue,brushSRGB:red,w:0.5))      (spike red+blue=(125,0,92))")
print("  magenta over grn → \(shaderMix(dstSRGB:green,brushSRGB:magenta,w:0.5))")
print("  yellow over red  → \(shaderMix(dstSRGB:red,brushSRGB:yellow,w:0.5))    (spike yellow+red=(234,109,32))")
print("Endpoint faithfulness (w small → ~dst):")
print("  blue over yellow w=0.05 → \(shaderMix(dstSRGB:yellow,brushSRGB:blue,w:0.05))  (≈yellow 245,219,?)")
