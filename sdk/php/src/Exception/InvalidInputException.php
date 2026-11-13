<?php
// SPDX-License-Identifier: AGPL-3.0-only
declare(strict_types=1);

namespace FormBackend\Exception;

/** The submitted fields cannot be represented faithfully (wrong type, bad UTF-8, ambiguous name, too large). Nothing was sent. */
final class InvalidInputException extends FormBackendException
{
}
