/*
 * Copyright (C) 2023 - present Instructure, Inc.
 *
 * This file is part of Canvas.
 *
 * Canvas is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License as published by the Free
 * Software Foundation, version 3 of the License.
 *
 * Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License along
 * with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import React, {useCallback, useEffect, useState} from 'react'
import {Button, CloseButton} from '@instructure/ui-buttons'
import {Flex} from '@instructure/ui-flex'
import {Heading} from '@instructure/ui-heading'
import {Tray} from '@instructure/ui-tray'
import {uid} from '@instructure/uid'
import {View} from '@instructure/ui-view'
import {
  IconAddLine,
  IconAssignmentLine,
  IconQuizLine,
  IconQuizSolid,
  IconQuestionLine,
} from '@instructure/ui-icons'
import ItemAssignToCard from './ItemAssignToCard'
import TrayFooter from '../Footer'
import {useScope as useI18nScope} from '@canvas/i18n'

const I18n = useI18nScope('differentiated_modules')

function itemTypeToIcon(itemType: string) {
  switch (itemType) {
    case 'assignment':
      return <IconAssignmentLine />
    case 'quiz':
      return <IconQuizLine />
    case 'lti-quiz':
      return <IconQuizSolid />
    default:
      return <IconQuestionLine />
  }
}

// TODO: need props to initialize with cards corresponding to current assignments
export interface ItemAssignToTrayProps {
  open: boolean
  onDismiss: () => void
  onSave: () => void
  courseId: string
  moduleItemId: string
  moduleItemName: string
  moduleItemType: string
  pointsPossible: string
}

// TODO: will eventually be ItemAssignToCardProps, I think
interface CardProps {
  isValid: boolean
}
interface CardMap {
  [key: string]: CardProps
}

export default function ItemAssignToTray({
  open,
  onDismiss,
  onSave,
  courseId,
  moduleItemId,
  moduleItemName,
  moduleItemType,
  pointsPossible,
}: ItemAssignToTrayProps) {
  const [assignToCards, setAssignToCards] = useState<CardMap>(() => {
    const cardId = uid('assign-to-card', 3)
    return {[cardId]: {isValid: true}} as CardMap
  })

  // TODO: data needs to come from api
  useEffect(() => {
    const cardId = uid('assign-to-card', 3)
    setAssignToCards({[cardId]: {isValid: true}} as CardMap)
  }, [courseId, moduleItemId])

  const handleAddCard = useCallback(() => {
    const cardId = uid('assign-to-card', 3)
    setAssignToCards({...assignToCards, [cardId]: {isValid: true}} as any)
  }, [assignToCards])

  const handleUpdate = useCallback(() => {
    onSave()
  }, [onSave])

  const handleDeleteCard = useCallback(
    (cardId: string) => {
      const cards = {...assignToCards}
      delete cards[cardId]
      setAssignToCards(cards)
    },
    [assignToCards]
  )

  const handleCardValidityChange = useCallback(
    (cardId: string, isValid: boolean) => {
      const cards = {...assignToCards}
      cards[cardId].isValid = isValid
      setAssignToCards(cards)
    },
    [assignToCards]
  )

  const allCardsValid = useCallback(() => {
    return Object.values(assignToCards).every(card => card.isValid)
  }, [assignToCards])

  function Header() {
    const icon = itemTypeToIcon(moduleItemType)
    return (
      <Flex.Item margin="medium 0 0 0" padding="0 medium" width="100%">
        <CloseButton
          onClick={onDismiss}
          screenReaderLabel={I18n.t('Close')}
          placement="end"
          offset="small"
        />
        <Heading as="h3">
          {icon} {moduleItemName}
        </Heading>
        <View as="div" margin="medium 0 0 0">
          {renderItemType()} {pointsPossible ? `| ${pointsPossible}` : ''}
        </View>
      </Flex.Item>
    )
  }

  function renderItemType() {
    switch (moduleItemType) {
      case 'assignment':
        return I18n.t('Assignment')
      case 'quiz':
        return I18n.t('Quiz')
      case 'lti-quiz':
        return I18n.t('Quiz')
      default:
        return ''
    }
  }

  function renderCards() {
    const cardIds = Object.keys(assignToCards)
    const cardCount = cardIds.length
    return cardIds.map(cardId => {
      const props = assignToCards[cardId]
      return (
        <View key={cardId} as="div" margin="small 0 0 0">
          <ItemAssignToCard
            {...props}
            cardId={cardId}
            onDelete={cardCount === 1 ? undefined : handleDeleteCard}
            onValidityChange={handleCardValidityChange}
          />
        </View>
      )
    })
  }

  function Body() {
    return (
      <Flex.Item padding="small medium 0" shouldGrow={true} shouldShrink={true}>
        {renderCards()}
        <Button onClick={handleAddCard} margin="small 0 0 0" renderIcon={IconAddLine}>
          {I18n.t('Add')}
        </Button>
      </Flex.Item>
    )
  }

  function Footer() {
    return (
      <Flex.Item margin="small 0 0 0" width="100%">
        <TrayFooter
          disableUpdate={!allCardsValid()}
          updateButtonLabel={I18n.t('Save')}
          onDismiss={onDismiss}
          onUpdate={handleUpdate}
        />
      </Flex.Item>
    )
  }

  return (
    <Tray
      label={I18n.t('Edit assignment %{name}', {
        name: moduleItemName,
      })}
      open={open}
      placement="end"
      size="regular"
    >
      <Flex direction="column" height="100vh" width="100%">
        {Header()}
        {Body()}
        {Footer()}
      </Flex>
    </Tray>
  )
}