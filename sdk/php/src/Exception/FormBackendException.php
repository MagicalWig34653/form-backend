<?php
// SPDX-License-Identifier: AGPL-3.0-only
declare(strict_types=1);

namespace FormBackend\Exception;

/** Base class of every error raised by the SDK. Messages never contain field values or key material. */
class FormBackendException extends \RuntimeException
{
}
