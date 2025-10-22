## 작동 방식

---

1. Validation
작성된 manifest 파일들이 올바른지 검증합니다. 올바르지 않은 경우 Fail이 발생하고, Github Actions의 경우 apply 단계로 넘어가지 않습니다.
2. Diff with Current Records
현재 Cloudflare에 설정된 레코드들과 manifest 파일들을 비교하여 변경사항이 있는지 확인합니다. 변경사항이 없는 경우 apply 단계를 건너뜁니다.
3. Apply
manifest 파일들을 바탕으로 Cloudflare에 레코드를 추가, 수정, 삭제합니다.
4. Cron Job
매 시 00분에 자동으로 Validate, Apply 작업을 수행해여 Cloudflare 레코드와 manifest 파일들이 동기화되도록 합니다.