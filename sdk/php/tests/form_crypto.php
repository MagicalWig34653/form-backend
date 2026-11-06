<?php
// SPDX-License-Identifier: AGPL-3.0-only
// Isolated synthetic test harness. Never load legacy/bootstrap/configuration files.
declare(strict_types=1);
function check(bool $ok, string $label): void { if (!$ok) throw new RuntimeException($label); }
function hx(string $s): string { $v=hex2bin($s); if ($v===false) throw new RuntimeException('hex'); return $v; }
function extractKey(string $salt,string $ikm): string { return hash_hmac('sha256',$ikm,$salt===''?str_repeat("\0",32):$salt,true); }
function expandKey(string $prk,string $info,int $length): string {
    $t='';$out='';for($i=1;strlen($out)<$length;$i++) { $t=hash_hmac('sha256',$t.$info.chr($i),$prk,true);$out.=$t; }return substr($out,0,$length);
}
function le(string $suite,string $salt,string $label,string $ikm): string { return extractKey($salt,'HPKE-v1'.$suite.$label.$ikm); }
function lx(string $suite,string $prk,string $label,string $info,int $length): string { return expandKey($prk,pack('n',$length).'HPKE-v1'.$suite.$label.$info,$length); }
function schedule(string $sk,string $peer,string $enc,string $recipient,string $info): array {
    $kem='KEM'.pack('n',32);$suite='HPKE'.pack('nnn',32,1,2);
    $dh=sodium_crypto_scalarmult($sk,$peer);
    $shared=lx($kem,le($kem,'','eae_prk',$dh),'shared_secret',$enc.$recipient,32);
    $context="\0".le($suite,'','psk_id_hash','').le($suite,'','info_hash',$info);
    $secret=le($suite,$shared,'secret','');
    return ['shared_secret'=>$shared,'key_schedule_context'=>$context,'key'=>lx($suite,$secret,'key',$context,32),'base_nonce'=>lx($suite,$secret,'base_nonce',$context,12)];
}
function gcm(string $pt,string $key,string $nonce,string $aad): string { return sodium_crypto_aead_aes256gcm_encrypt($pt,$aad,$nonce,$key); }
function ungcm(string $ct,string $key,string $nonce,string $aad): string {
    $pt=sodium_crypto_aead_aes256gcm_decrypt($ct,$aad,$nonce,$key);if($pt===false)throw new RuntimeException('authentication');return $pt;
}
function hpkeSeal(string $pt,string $pk,string $skE,string $info,string $aad): array {
    $enc=sodium_crypto_scalarmult_base($skE);$s=schedule($skE,$pk,$enc,$pk,$info);return [$enc,gcm($pt,$s['key'],$s['base_nonce'],$aad)];
}
function hpkeOpen(string $ct,string $enc,string $sk,string $info,string $aad): string {
    $s=schedule($sk,$enc,$enc,sodium_crypto_scalarmult_base($sk),$info);return ungcm($ct,$s['key'],$s['base_nonce'],$aad);
}
function packet(string $pt,string $pk,string $skE,string $cek,string $iv): string {
    $kid=substr(hash('sha256',$pk),0,16);[$enc,$wrap]=hpkeSeal($cek,$pk,$skE,'kubus-anfrage v2',$kid);$ct=gcm($pt,$cek,$iv,'KUBUS-AEAD:2');
    return 'KUBUS-AEAD:2|'.$kid.'|hpke|'.base64_encode($enc).':'.base64_encode($wrap).'|'.base64_encode($iv).'|'.base64_encode(substr($ct,0,-16)).'|'.base64_encode(substr($ct,-16));
}
function parsePacket(string $wire): array {
    $p=explode('|',$wire);check(count($p)===7 && $p[0]==='KUBUS-AEAD:2' && preg_match('/\A[0-9a-f]{16}\z/',$p[1])===1 && in_array($p[2],['hpke','sym'],true),'format');
    $w=explode(':',$p[3]);check(count($w)===2,'wrap format');$raw=[];
    foreach([$w[0],$w[1],$p[4],$p[5],$p[6]] as $i=>$s) { $d=base64_decode($s,true);check($d!==false && base64_encode($d)===$s,'base64');$n=[$p[2]==='hpke'?32:12,48,12,null,16][$i];check($n===null || strlen($d)===$n,'length');$raw[]=$d; }
    return [$p[1],$p[2],...$raw];
}
function openPacket(string $wire,string $sk): string {
    [$kid,$wrap,$a,$b,$iv,$ct,$tag]=parsePacket($wire);check($kid===substr(hash('sha256',sodium_crypto_scalarmult_base($sk)),0,16),'kid');
    $cek=$wrap==='hpke'?hpkeOpen($b,$a,$sk,'kubus-anfrage v2',$kid):ungcm($b,hash_hkdf('sha256',$sk,32,'kubus-langzeit v1',''),$a,$kid);
    check(strlen($cek)===32,'cek');return ungcm($ct.$tag,$cek,$iv,'KUBUS-AEAD:2');
}
function sortedPHP(mixed $v): mixed { if(!is_array($v))return $v;if(!array_is_list($v))ksort($v,SORT_STRING);return array_map('sortedPHP',$v); }
function canonical(array $fields,array $files=[]): string {
    ksort($files,SORT_STRING);$out=[];
    foreach($files as $key=>$f) { $part=filePart($f);if($part!==null)$out[$key]=$part; }
    return json_encode(['fields'=>sortedPHP($fields),'files'=>$out],JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR);
}
function filePart(array $f): ?array {
    if(is_array($f['name']??null)) { $out=[];foreach($f['name'] as $k=>$name) { $part=filePart(['name'=>$name,'type'=>$f['type'][$k]??'','error'=>$f['error'][$k]??4,'size'=>$f['size'][$k]??0,'content'=>$f['content'][$k]??null]);if($part!==null)$out[]=$part; }return $out?:null; }
    if((int)($f['error']??4)!==0)return null;
    return ['name'=>(string)($f['name']??''),'type'=>(string)($f['type']??''),'error'=>0,'size'=>(int)($f['size']??0),'sha256'=>isset($f['content'])?hash('sha256',$f['content']):null];
}
function signatureText(string $method,string $path,string $uuid,string $ts,string $body): string {
    $path='/'.ltrim((string)(parse_url($path,PHP_URL_PATH)?:$path),'/');$path=rtrim($path,'/');return "KUBUS-V2\n".strtoupper($method)."\n".$path.'/?f='.rawurlencode($uuid)."\n".$ts."\n".hash('sha256',$body);
}
function addLE(string $a,string $b): string { $out='';$c=0;for($i=0;$i<32;$i++){$t=ord($a[$i])+ord($b[$i])+$c;$out.=chr($t&255);$c=$t>>8;}check($c===0,'overflow');return $out; }
function sodiumVerify(string $sig,string $msg,string $pk): bool { try { return sodium_crypto_sign_verify_detached($sig,$msg,$pk); } catch (SodiumException) { return false; } }
/** Strict-Ed25519 negative/positive vectors (contract signatur.md A7); expectations are asserted against libsodium. */
function ed25519StrictCases(): array {
    $L=hx('edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010');
    $pair=sodium_crypto_sign_seed_keypair(str_repeat("\x66",32));$sk=sodium_crypto_sign_secretkey($pair);$pk=sodium_crypto_sign_publickey($pair);
    $msg='ed25519 strict vector message (synthetic)';$sig=sodium_crypto_sign_detached($msg,$sk);$R=substr($sig,0,32);$S=substr($sig,32);
    $identity="\x01".str_repeat("\0",31);$zero=str_repeat("\0",32);
    $nonCanonicalIdentity="\xee".str_repeat("\xff",30)."\x7f"; // y = p + 1
    $o8a=hx('c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a');
    $c=[];$add=function(string $id,string $pk,string $msg,string $sig,bool $expect) use (&$c){$c[]=['id'=>$id,'publicKey'=>bin2hex($pk),'message'=>bin2hex($msg),'signature'=>bin2hex($sig),'expected'=>$expect];};
    $add('valid-positive',$pk,$msg,$sig,true);
    $add('message-tampered',$pk,$msg.'x',$sig,false);
    $add('s-equals-l',$pk,$msg,$R.$L,false);
    $add('s-plus-l',$pk,$msg,$R.addLE($S,$L),false);
    $add('s-all-ff',$pk,$msg,$R.str_repeat("\xff",32),false);
    $add('public-key-small-order-identity',$identity,$msg,$identity.$zero,false);
    $add('public-key-small-order-zero-y',$zero,$msg,$identity.$zero,false);
    $add('public-key-small-order-8',$o8a,$msg,$identity.$zero,false);
    $add('public-key-noncanonical-identity',$nonCanonicalIdentity,$msg,$identity.$zero,false);
    $add('r-small-order-identity',$pk,$msg,$identity.$S,false);
    $add('r-noncanonical',$pk,$msg,$nonCanonicalIdentity.$S,false);
    $add('signature-63-bytes',$pk,$msg,substr($sig,0,63),false);
    $add('signature-65-bytes',$pk,$msg,$sig."\0",false);
    $add('public-key-31-bytes',substr($pk,0,31),$msg,$sig,false);
    $add('public-key-33-bytes',$pk."\0",$msg,$sig,false);
    return $c;
}
function fails(callable $fn): void { try {$fn();}catch(Throwable){return;}throw new RuntimeException('expected rejection'); }

function canonicalInputs(): array { return [[],['z'=>'Grüße / 🌍', 'a'=>['x'=>true,'n'=>null,'i'=>-42],'line'=>"\0\n\t\u{2028}\u{2029}"], [2=>'two',0=>'zero'], [1=>'one',0=>'zero'], ['10'=>'ten','2'=>'two','01'=>'leading'], ['list'=>['b','a'],'empty'=>[]]]; }
function canonicalFiles(int $i): array { return $i===1?['upload'=>['name'=>['b.bin','skip','missing'],'type'=>['application/octet-stream','',''],'error'=>[0,4,0],'size'=>[3,0,0],'content'=>["\0\xff\x01",null,null]]]:[]; }
$fixtures=__DIR__.'/../../../backend/Tests/FormCryptoTests/Fixtures/';
try {
    check(extension_loaded('sodium') && sodium_crypto_aead_aes256gcm_is_available(),'sodium AES unavailable');
    $v=json_decode(file_get_contents($fixtures.'rfc9180.json'),true,512,JSON_THROW_ON_ERROR);
    check([$v['mode'],$v['kem_id'],$v['kdf_id'],$v['aead_id']]===[0,32,1,2],'suite');
    $s=schedule(hx($v['skEm']),hx($v['pkRm']),hx($v['enc']),hx($v['pkRm']),hx($v['info']));
    foreach($s as $k=>$value)check(bin2hex($value)===$v[$k],$k);
    $e=$v['encryptions'][0];[$enc,$ct]=hpkeSeal(hx($e['pt']),hx($v['pkRm']),hx($v['skEm']),hx($v['info']),hx($e['aad']));
    check(bin2hex($enc)===$v['enc'] && bin2hex($ct)===$e['ct'],'RFC seal');check(hpkeOpen($ct,$enc,hx($v['skRm']),hx($v['info']),hx($e['aad']))===hx($e['pt']),'RFC open');
    echo "PASS RFC9180 suite, shared_secret, context, key, nonce, seal/open sequence 0\n";
    if(($argv[1]??'')==='--generate-ed25519') {
        $cases=ed25519StrictCases();foreach($cases as $c)check(sodiumVerify(hx($c['signature']),hx($c['message']),hx($c['publicKey']))===$c['expected'],'libsodium disagrees: '.$c['id']);
        file_put_contents($fixtures.'ed25519-strict.json',json_encode(['notice'=>'PUBLIC SYNTHETIC TEST KEYS ONLY','source'=>'PHP ext-sodium sodium_crypto_sign_verify_detached','cases'=>$cases],JSON_PRETTY_PRINT|JSON_THROW_ON_ERROR)."\n");echo "GENERATED ed25519-strict.json (".count($cases)." cases, libsodium agrees)\n";exit(0);
    }
    if(($argv[1]??'')==='--generate') {
        $sk=str_repeat("\x11",32);$pk=sodium_crypto_scalarmult_base($sk);$skE=str_repeat("\x22",32);$cek=str_repeat("\x33",32);$iv=str_repeat("\x44",12);
        $cases=[];foreach(['',"Grüße / 🌍", "\0\xff\x01\x80"] as $i=>$pt)$cases[]=['id'=>'php-'.$i,'plaintext'=>bin2hex($pt),'packet'=>packet($pt,$pk,$skE,$cek,$iv)];
        $canonicalCases=[];
        $inputs=canonicalInputs();
        $seed=str_repeat("\x55",32);$pair=sodium_crypto_sign_seed_keypair($seed);
        foreach($inputs as $i=>$input) {
            $files=canonicalFiles($i);
            $body=canonical($input,$files);$text=signatureText('post','https://example.invalid/api/v2/submit///?ignored=yes','a b/ü','1793145600',$body);
            $canonicalCases[]=['id'=>'canonical-'.$i,'canonical'=>bin2hex($body),'text'=>bin2hex($text),'signature'=>bin2hex(sodium_crypto_sign_detached($text,sodium_crypto_sign_secretkey($pair)))];
        }
        $kid=substr(hash('sha256',$pk),0,16);
        $wrap=gcm($cek,hash_hkdf('sha256',$sk,32,'kubus-langzeit v1',''),$iv,$kid);
        $payload=gcm('', $cek,$iv,'KUBUS-AEAD:2');
        $sym='KUBUS-AEAD:2|'.$kid.'|sym|'.base64_encode($iv).':'.base64_encode($wrap).'|'.base64_encode($iv).'||'.base64_encode($payload);
        $manifest=['symPacket'=>$sym,'notice'=>'PUBLIC SYNTHETIC TEST KEYS ONLY - NEVER USE IN PRODUCTION','sk'=>bin2hex($sk),'pk'=>bin2hex($pk),'skE'=>bin2hex($skE),'cek'=>bin2hex($cek),'iv'=>bin2hex($iv),'seed'=>bin2hex($seed),'signPublic'=>bin2hex(sodium_crypto_sign_publickey($pair)),'packets'=>$cases,'canonical'=>$canonicalCases];
        file_put_contents($fixtures.'synthetic.json',json_encode($manifest,JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR)."\n");echo "GENERATED synthetic.json using PHP/ext-sodium\n";exit(0);
    }
    $m=json_decode(file_get_contents($fixtures.'synthetic.json'),true,512,JSON_THROW_ON_ERROR);
    foreach($m['packets'] as $p){check(packet(hx($p['plaintext']),hx($m['pk']),hx($m['skE']),hx($m['cek']),hx($m['iv']))===$p['packet'],'synthetic byte equality');check(openPacket($p['packet'],hx($m['sk']))===hx($p['plaintext']),'synthetic open');}
    check(openPacket($m['symPacket'],hx($m['sk']))==='', 'sym open');
    echo "PASS 3 PHP synthetic packets: byte equality and decrypt\n";
    foreach($m['canonical'] as $i=>$c) {
        $body=canonical(canonicalInputs()[$i],canonicalFiles($i));
        check(bin2hex($body)===$c['canonical'],'canonical bytes');
        $text=signatureText('post','https://example.invalid/api/v2/submit///?ignored=yes','a b/ü','1793145600',$body);
        check(bin2hex($text)===$c['text'],'signature text bytes');
        check(sodium_crypto_sign_verify_detached(hx($c['signature']),$text,hx($m['signPublic'])),'signature');
        check(!sodium_crypto_sign_verify_detached(hx($c['signature']),$text.'x',hx($m['signPublic'])),'signature tampering');
    }
    check(canonical([])==='{"fields":[],"files":[]}','empty canonical');fails(fn()=>canonical(['bad'=>"\xff"]));
    echo "PASS 6 canonical signature vectors and invalid UTF-8 rejection\n";
    $strict=json_decode(file_get_contents($fixtures.'ed25519-strict.json'),true,512,JSON_THROW_ON_ERROR)['cases'];
    foreach($strict as $c)check(sodiumVerify(hx($c['signature']),hx($c['message']),hx($c['publicKey']))===$c['expected'],'ed25519 strict '.$c['id']);
    echo "PASS ".count($strict)." strict Ed25519 vectors (libsodium)\n";
    $wire=$m['packets'][0]['packet'];foreach([$wire."\n",str_replace('hpke','HPKE',$wire),str_replace('KUBUS-AEAD:2','KUBUS-AEAD:1',$wire),$wire.'|'] as $bad)fails(fn()=>parsePacket($bad));
    $p=explode('|',$wire);$p[6]=base64_encode(str_repeat("\0",16));fails(fn()=>openPacket(implode('|',$p),hx($m['sk'])));fails(fn()=>sodium_crypto_scalarmult(hx($m['sk']),str_repeat("\0",32)));
    echo "PASS parser, tag tampering and null-DH rejection\n";
    $swift=json_decode(file_get_contents(getenv('FORM_SWIFT_EXPORT')?:__DIR__.'/../../../backend/.build/swift-output.json'),true,512,JSON_THROW_ON_ERROR);
    foreach($swift['packets'] as $p)check(openPacket($p['packet'],hx($m['sk']))===hx($p['plaintext']),'Swift -> PHP decrypt');
    foreach($swift['signatures'] as $c)check(sodium_crypto_sign_verify_detached(hx($c['signature']),hx($c['text']),hx($m['signPublic'])),'Swift -> PHP verify');
    echo "PASS Swift -> PHP: 3 packets decrypted, 6 signatures verified\nALL PHP TESTS PASSED\n";
}catch(Throwable $e){fwrite(STDERR,"FAIL ".$e->getMessage()."\n");exit(1);}
