## How to use

추후 레포지토리 인수인계 시 인수자가 Repo 등의 설정을 이해할 수 있도록 문서를 작성해두었습니다.

### 목차
0. 작동 방식
1. Cloudflare 토큰 발급
2. Github Actions secret 설정
3. Repo 관리

### 1. 작동 방식
아래 명령어를 통해 쉘 스크립트를 실행할 수 있습니다.
- Validation
작성된 manifest 파일들이 올바른지 검증합니다. 올바르지 않은 경우 Fail이 발생하고, Github Actions의 경우 apply 단계로 넘어가지 않습니다.
```
bash scripts/validate_manifests.sh
```
<br />
- Apply
2번 항목을 참고하여 필요한 값들을 생성 또는 불러오시기 바랍니다. 아래 값들은 유출을 절대 금하며, 3번의 GA Secrets를 통하여 관리하여야 합니다.
```
bash scripts/apply_records.sh ${CLOUDFLARE_API_TOKEN} \
    sunrin.io={SUNRIN_IO_ZONE_ID} \
    swfestival.kr={SWFESTIVAL_KR_ZONE_ID}
```

### 2. Cloudflare 토큰 발급
Github Actions를 통한 자동화 시 Cloudflare API 토큰이 필요합니다. 아래 절차대로 토큰을 발급해야 합니다.  
**주의: 발급된 토큰은 절대 유출되지 않도록 주의하여야 합니다.**
1. Cloudflare -> My profile -> API Tokens에서 "Create Token"을 클릭합니다.  
2. Create Custom Token을 클릭하고 아래 권한들을 추가합니다. 이름은 자유롭게 설정합니다.
    - Zone -> DNS -> Edit
    - Zone -> DNS Settings -> Edit
    - Zone -> Zone -> Edit
    - Zone -> Zone Settings -> Edit
3. Zone Resources는 "Include, All Zones from an account, Sunrin Internet High School"로 설정합니다.
4. (선택) Client IP Address Filtering을 설정할 수 있습니다. 
5. (선택) TTL을 설정할 수 있습니다. 원하는 기간동안 설정하며, 무제한이 아닌 기간제로 발급 시 토큰 만료에 **각별히** 주의하여야 합니다.
6. Continue to summary를 클릭하고 토큰을 생성합니다.

### 3. Github Actions secret 설정
아래 절차대로 Github Actions secret을 설정합니다.
1. Settings -> Secrets and variables -> Actions로 이동합니다.
2. New repository secret를 클릭하고, 아래 값들을 추가합니다.
    - Name: CF_TOKEN  
      Value: 2번에서 발급한 Cloudflare API 토큰
    - Name: CF_ZONE_SUNRIN_IO  
      Value: sunrin.io 도메인의 Zone ID
    - Name: CF_ZONE_SWFESTIVAL_KR  
      Value: swfestival.kr 도메인의 Zone ID
3. 위 값들은 유출되지 않게 **각별히** 주의하시기 바랍니다.

### 4. Repo 관리
도메인 레코드의 추가 및 수정이 필요할 경우, PR을 통해 생성하는 것을 권장합니다.  
Repo를 fork하고, examples.yaml 양식에 맞춰 작성한 후 PR을 생성합니다.  
PR Approve 시 PR Author가 임의로 파일을 삭제 또는 생성, 수정하지 않았는지 **철저히 검증**하여야 합니다.  