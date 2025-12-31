<?php

namespace OldSabre\DAV\Exception;

use OldSabre\DAV;

/**
 * RequestedRangeNotSatisfiable
 *
 * This exception is normally thrown when the user
 * request a range that is out of the entity bounds.
 *
 * @copyright Copyright (C) 2007-2015 fruux GmbH (https://fruux.com/).
 * @author Evert Pot (http://evertpot.com/)
 * @license http://sabre.io/license/ Modified BSD License
 */
class RequestedRangeNotSatisfiable extends DAV\Exception {

    /**
     * returns the http statuscode for this exception
     *
     * @return int
     */
    public function getHTTPCode() {

        return 416;

    }

}

