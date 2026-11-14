<?php
// SPDX-License-Identifier: AGPL-3.0-only
// Minimal "customer website" for backend/e2e-legacy.sh: one page that embeds the OLD PHP SDK of the previous backend exactly as a
// customer page does (loadForm() on render, send() on POST) and prints what the page would act on as JSON.
// ?sdk=v2 -> providers/Clients/BackendV2.php (unchanged), ?sdk=v1 -> providers/Clients/Backend.php (copy with only the host replaced,
// because v1 has the backend host hard-coded).
declare(strict_types=1);

$dir = (string)getenv('LEGACY_SDK_DIR');
if (($_GET['sdk'] ?? 'v2') === 'v1') {
    require (string)getenv('LEGACY_V1_COPY');
    $backend = new Backend((string)getenv('E2E_FORM_UUID'));
} else {
    require $dir . '/providers/Clients/BackendV2.php';
    $backend = new BackendV2((string)getenv('LEGACY_V2_CONFIG'));
}
$ok = $backend->loadForm();
header('Content-Type: application/json');
if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    $status = $backend->send();
    echo json_encode(['phase' => 'send', 'status' => $status, 'message' => $backend::getEndbenutzerFehlermeldung($status)]);
    exit;
}
echo json_encode([
    'phase' => 'load',
    'ok' => $ok,
    'status' => $backend->getResponseCode(),
    'sitekey' => $backend->getTurnstileSitekey(),
    'mode' => $backend->getFormularMode(),
    'csrf' => $backend->getCsrfToken(),
    'fields' => method_exists($backend, 'getFields') ? array_column($backend->getFields(), 'name') : null,
]);
